#
# This makefile guides you through mysql replication setup as described in:
#          http://plusbryan.com/mysql-replication-without-downtime
# 
# This is a gnumake file.
# It assumes centos environment. 
# Should work for debian or other *nixes with minor modifications.
#

all:
force:

#### parameters
# edit these parameters to match your arrangement, or put them in local.mk

-include local.mk

replication_user?=replicant
replication_password?=sesami

master_addr?=192.168.1.100
master_user?=root
master_password?=sesami
master_mysql_args?=-u$(master_user) -p$(master_password) -h $(master_addr)

slave_addr?=192.168.1.101
slave_user?=root
slave_password?=sesami
slave_mysql_args?=-u$(slave_user) -p$(slave_password)

#### master setup
# run these targets on the master host.

# ensure minimal master configuration.
# if these conditions are not met, edit config file and restart.
master-config-check: force
	grep 'log-bin=mysql-bin' /etc/my.cnf
	grep 'server-id=1'       /etc/my.cnf

# setup the replication user on master.
master-replication-user:
	echo 'CREATE USER $(replication_user)@$(slave_addr);' | $(master_mysql)
	echo "GRANT REPLICATION SLAVE ON *.* TO '$(replication_user)'@'$(slave_addr)' IDENTIFIED BY '$(replication_password)';" \
	| $(mysql_mysql)

# dump with replication coordinate info.
master-dump:
	mysqldump \
		$(master_mysql_args) \
		--skip-lock-tables \
		--single-transaction \
		--flush-logs \
		--hex-blob \
		--master-data=2 \
		-A \
	> /var/tmp/master.dump

	grep -m 1 MASTER_LOG_POS master.dump | tee /var/tmp/master.coordinate

	gzip /var/tmp/master.dump

#### slave
# following is meant to be run on slave.

# make sure you can connect as replication user to master from slave host.
replication-check:
	echo 'show databases;' | mysql -h $(master_addr) -u$(replication_user) -p$(replication_password)

# ensure minimal configuration for slave.
slave-config-check:
	grep '^server-id=' /etc/my.cnf
	if grep '^server-id=1' /etc/my.cnf > /dev/null; then echo server-id must be different from master; false; fi

# fetch the dump from master
/var/tmp/master.dump.gz:
	scp $(master_addr):/var/tmp/master.{dump.gz,coordinate} /var/tmp/

# load server config
$(eval $(shell grep -Po "MASTER_LOG_FILE='[^']+'" /var/tmp/master.coordinate | tr -d "'"))
$(eval $(shell grep -Po "MASTER_LOG_POS=\d+"      /var/tmp/master.coordinate | tr -d "'"))

# for debugging
show-master-coordinate:
	@echo $(MASTER_LOG_FILE)
	@echo $(MASTER_LOG_POS)

# compose slave sql from the master.coordinate file.
define slave_sql
	CHANGE MASTER TO \
		MASTER_HOST='$(master_addr)',\
		MASTER_USER='$(replication_user)',\
		MASTER_PASSWORD='$(replication_password)', \
		MASTER_LOG_FILE='$(MASTER_LOG_FILE)', \
		MASTER_LOG_POS=$(MASTER_LOG_POS); 
	START SLAVE;
	SHOW SLAVE STATUS \G
endef
export slave_sql

# write out the slave sql.
slave.sql:
	@if [ -z "$(MASTER_LOG_FILE)" ]; then need master_log_file; false; fi
	@if [ -z "$(MASTER_LOG_POS)" ]; then need master_log_pos; false; fi
	@echo $$slave_sql | sed 's/; */;\n\n/g' | sed 's/,/,\n/g' > $@

# configure the slave to track the master
slave-setup: slave.sql /var/tmp/master.dump.gz
	zcat /var/tmp/master.dump.gz | myqsl $(slave_mysql_args)
	cat $< | mysql $(slave_mysql_args)
