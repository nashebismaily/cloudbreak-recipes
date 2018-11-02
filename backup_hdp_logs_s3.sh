## Author: Nasheb Ismaily
## 
## Description: Searches the HDP base log directory (/var/log) for any directories owned by HDP system groups.
##		Creates a list of all log files that need to be backed up.
##		Adds user specified logs owned by root system group to the list.
##		Tars the logs in the list with the name: hdp-logs.tar.gz
##		Searches for running yarn application logs and adds them to the list.
##		Tars the logs in the list with the name: yarn-running-application-logs.tar.gz
##		Searches for historical yarn application logs and adds them to the list.
##		Tars the logs in the list with the name: yarn-historical-application-logs.tar.gz
##		Zips all tars together as: YYMMDD_HHmmSS-Hostname.zip
##		Installs awscli using pip
##		Copies zip file to s3 using awscli

# Enable Debug Mode
set -x

####################  User Defined Variables #####################

### AWS Connection information ###

# S3 Bucket Format: s3://${AWS_S3_BUCKET}/${AWS_S3_FOLDER_FOR_BACKUPS}/${HDP_CLUSTER_NAME}/
# ${HDP_CLUSTER_NAME} is auto-determined in the script
AWS_ACCESS_KEY_ID=
AWS_SECRET_ACCESS_KEY=
AWS_S3_BUCKET=
AWS_S3_FOLDER_FOR_BACKUPS=

### HDP Log Information ###

# HDFS SUPERUSER
HDFS_SUPERUSER=hdfs

# Top level directory to search for HDP logs
HDP_LOG_BASE_DIR=/var/log

# Directory containing ambari agent logs, used to obtain Ambari - HDP Cluster Name
AMBARI_AGENT_LOG_DIR=/var/log/ambari-agent

# Directory containing ambari server logs, used to obtain Ambari - HDP Cluster Name
AMBARI_SERVER_LOG_DIR=/var/log/ambari-server

# Yarn application logs (yarn.nodemanager.log-dirs)
YARN_APPLICATION_LOGS_DIR=/hadoop/yarn/log

# HDP system groups            
declare -a HDP_SYSTEM_GROUPS=(  
                                accumulo
                                activity_analyzer
                                ambari-qa
                                ams
                                atlas
                                hadoop
                                hbase
                                hcat
                                hdfs
                                hive
                                infra-solr
                                kafka
                                kms
                                knox
                                livy
                                mapred
                                oozie
                                phoenix
                                pig
                                ranger
                                slider
                                spark
                                sqoop
                                storm
                                tez
                                yarn
                                yarn-ats
                                zeppelin
                                zookeeper
                             )

# Logs owned by the root system group
declare -a ROOT_OWNED_LOGS=(
				'/var/log/ambari-server' 
				'/var/log/ambari-agent'
			   )

####################  Internal Variables #####################

# Get current data for tar file
DATE=$(date '+%Y%m%d_%H%M%S')

# Temporary directory to store the log backups
TEMP_BACKUP_DIR=/tmp/hdp-backup-${DATE}

# Get the fully qualified hostname of the server
HOSTNAME_FQ=$(hostname -f)

# Get the hostname of the server
HOSTNAME=$(hostname | cut -d "." -f 1)

# HDP logs compressed backup filename
HDP_LOGS_BACKUP_FILE_NAME=hdp-logs

# YARN running application compressed backup filename
YARN_RUNNING_APPLICATION_LOGS_BACKUP_FILE_NAME=yarn-running-application

# YARN historical application compressed backup filename
YARN_HISTORICAL_APPLICATION_LOGS_BACKUP_FILE_NAME=yarn-historical-application

# Name of the ZIP file contained HDP logs and YARN application logs
ZIPPED_BACKUP_FILE_NAME="${DATE}-${HOSTNAME}.zip"

# List of HDP logs of current host
declare -a HDP_LOGS_FOR_BACKUP

# List of YARN application logs for current host
declare -a YARN_APPLICATION_LOGS_FOR_BACKUP

# List of tars to zip for upload to AWS
declare -a TARS_FOR_ZIP

# Default hadoop configuration directory
HADOOP_CONF_DIR=/etc/hadoop/conf

# Hadoop keytab directory
HADOOP_KEYTAB_DIR=/etc/security/keytabs

# HDFS headles keytab
HDFS_HEADLESS_KEYTAB=hdfs.headless.keytab

# Hadoop authentiaction property
HADOOP_AUTH_PROPERTY=hadoop.security.authentication

# Hadoop filesystem property
HADOOP_FS_PROPERTY=fs.defaultFS

# Hadoop High Availablity property
HADOOP_HA_PROPERTY=dfs.nameservices

# Hadoop High Availability Server 1 Property
HADOOP_HA_SERVER_1_PROPERTY="dfs.namenode.rpc-address.*.nn1"

# Hadoop High Availability Server 2 Property
HADOOP_HA_SERVER_2_PROPERTY="dfs.namenode.rpc-address.*.nn2"

# YARN application logs directory in HDFS
YARN_APP_LOG_DIR_HDFS=/app-logs

# Inital Kerberos cluster state to No
KERBEROS_ENABLED=0

#########################  Begin  #########################

###### Complete Prerequisites ######

# Install dependecies
yum -y install tar zip python-pip

# Install awscli
pip install awscli

# Make backup directory
mkdir -p ${TEMP_BACKUP_DIR} && chmod 777 ${TEMP_BACKUP_DIR}

###### HDP and Ambari System Logs ######

# Obtain list of log directories to backup based on system groups
for system_group in "${HDP_SYSTEM_GROUPS[@]}"
do
   # Get logs for curernt system group
   log_dirs=$(find  ${HDP_LOG_BASE_DIR} -maxdepth 1 -type d -group ${system_group})
   
   # No logs exist for current system group
   if [ -z "${log_dirs}" ]; then
       continue
   fi

   # Convert list of logs into array
   IFS=$'\n'
   logs=($log_dirs)

   # Add logs for system group to full list of logs to backup
   for log in "${logs[@]}"
   do
       log_dir=$(echo ${log} | cut -d "/" -f 4)
       HDP_LOGS_FOR_BACKUP=("${HDP_LOGS_FOR_BACKUP[@]}" "${log_dir}")
   done
done

# Add root owned directores to backup list
for root_owned_log in "${ROOT_OWNED_LOGS[@]}"
do
    # Skip directory if it doesn't exist
    if [ ! -d "${root_owned_log}" ]; then
        continue
    fi

    # Add root owned logs to full list of logs to backup
    log_dir=$(echo ${root_owned_log} | rev | cut -d "/" -f 1 | rev)
    HDP_LOGS_FOR_BACKUP=("${HDP_LOGS_FOR_BACKUP[@]}" "${log_dir}")
done

# Create the compressed backup of HDP log files
tar_command=$( IFS=$' '; echo "tar -zcvf ${TEMP_BACKUP_DIR}/${HDP_LOGS_BACKUP_FILE_NAME}.tar.gz --transform 's,^,${HDP_LOGS_BACKUP_FILE_NAME}/,' -C ${HDP_LOG_BASE_DIR} ${HDP_LOGS_FOR_BACKUP[*]}" )
eval ${tar_command}

# Add HDP logs to zip
if [ -f "${TEMP_BACKUP_DIR}/${HDP_LOGS_BACKUP_FILE_NAME}.tar.gz" ]; then
    TARS_FOR_ZIP+=("${HDP_LOGS_BACKUP_FILE_NAME}.tar.gz")
fi

###### YARN Running Application Logs  ######

# Add running yarn application logs to backup list
if [ -d ${YARN_APPLICATION_LOGS_DIR} ]; then

    log_dirs=$(find ${YARN_APPLICATION_LOGS_DIR}/* -type d)
    
    # Yarn application logs found
    if [ ! -z "${log_dirs}" ]; then

       # Convert list of logs into array
       IFS=$'\n'
       logs=($log_dirs)

       # Add logs for system group to full list of logs to backup
       for log in "${logs[@]}"
       do
           log_dir=$(echo ${log} | rev | cut -d "/" -f 1 | rev)
           YARN_APPLICATION_LOGS_FOR_BACKUP=("${YARN_APPLICATION_LOGS_FOR_BACKUP[@]}" "${log_dir}")
       done 
    fi
fi

# Create the compressed backup of YARN running application log files
if [ ${#YARN_APPLICATION_LOGS_FOR_BACKUP[@]} -ne 0 ]; then
    tar_command=$( IFS=$' '; echo "tar -zcvf ${TEMP_BACKUP_DIR}/${YARN_RUNNING_APPLICATION_LOGS_BACKUP_FILE_NAME}.tar.gz --transform 's,^,${YARN_RUNNING_APPLICATION_LOGS_BACKUP_FILE_NAME}/,' -C ${YARN_APPLICATION_LOGS_DIR} ${YARN_APPLICATION_LOGS_FOR_BACKUP[*]}" )
    eval ${tar_command}
fi

# Add YARN running application logs to zip
if [ -f "${TEMP_BACKUP_DIR}/${YARN_RUNNING_APPLICATION_LOGS_BACKUP_FILE_NAME}.tar.gz" ]; then
    TARS_FOR_ZIP+=("${YARN_RUNNING_APPLICATION_LOGS_BACKUP_FILE_NAME}.tar.gz")
fi

###### YARN Historical Logs ######

# HDFS Client exists on this host
if [ -d ${HADOOP_CONF_DIR} ] ;then

    # Check if kerberos is enabled
    KERBEROS_ENABLED=$(grep -A 1 ${HADOOP_AUTH_PROPERTY} ${HADOOP_CONF_DIR}/core-site.xml | grep "<value>" |  sed -n 's:.*<value>\(.*\)</value>.*:\1:p' | grep "kerberos" | wc -l)

    # Kinit if kerberos is enabled
    if [ "${KERBEROS_ENABLED}" -ne "0" ]; then
        # Get the hdfs principal
	hdfs_principal=$(klist -kt ${HADOOP_KEYTAB_DIR}/${HDFS_HEADLESS_KEYTAB} |tail -1 | rev | cut -d ' ' -f 1 | rev)

	# kinit as hdfs principal
	kinit -kt ${HADOOP_KEYTAB_DIR}/${HDFS_HEADLESS_KEYTAB} ${hdfs_principal}
    fi

    # Check if namenode in HA
    namnenode_ha_enabled=$(grep -A 1 ${HADOOP_HA_PROPERTY} ${HADOOP_CONF_DIR}/hdfs-site.xml | wc -l)

    # NameNode HA not enabled
    if [ "$namnenode_ha_enabled" -eq "0" ]; then
        namenode_server=$(grep -A1 ${HADOOP_FS_PROPERTY} ${HADOOP_CONF_DIR}/core-site.xml |grep "<value>" |  sed -n 's:.*<value>\(.*\)</value>.*:\1:p' | cut -d ":" -f 2 | sed "s|\/||g")
    # If NameNode HA is enabled
    else
        namenode_server_1=$(grep -A1 ${HADOOP_HA_SERVER_1_PROPERTY} ${HADOOP_CONF_DIR}/hdfs-site.xml |grep "<value>" |  sed -n 's:.*<value>\(.*\)</value>.*:\1:p' | cut -d ":" -f 1)
        namenode_server_2=$(grep -A1 ${HADOOP_HA_SERVER_2_PROPERTY} ${HADOOP_CONF_DIR}/hdfs-site.xml |grep "<value>" |  sed -n 's:.*<value>\(.*\)</value>.*:\1:p' | cut -d ":" -f 1)
	
        # Cluster is NOT kerberized
        if [ "${KERBEROS_ENABLED}" -eq "0" ]; then
            nn1_active=$(su ${HDFS_SUPERUSER} -c "hdfs haadmin -getServiceState nn1" | grep "active" | wc -l)
            nn2_active=$(su ${HDFS_SUPERUSER} -c "hdfs haadmin -getServiceState nn2" | grep "active" | wc -l)
        # Cluster is kerberized
        else
            nn1_active=$(hdfs haadmin -getServiceState nn1 | grep "active" | wc -l)
            nn2_active=$(hdfs haadmin -getServiceState nn2 | grep "active" | wc -l)
        fi
    
        # NameNode 1 is active
        if [ "${nn1_active}" -eq "1" ]; then
            namenode_server=${namenode_server_1}    
        # NameNode 2 is active
        elif [ "${nn2_active}" -eq "1" ]; then 
            namenode_server=${namenode_server_2}
        # No active NameNodes
        else
            namenode_server="NONE"
        fi
    fi

    # Download the historical YARN application logs from HDFS
    NAMENODE_SERVER="no"
    if [ "${HOSTNAME_FQ}" = "${namenode_server}" ]; then
        NAMENODE_SERVER="yes"

    	# Cluster is NOT kerberized
    	if [ "$KERBEROS_ENABLED" -eq "0" ]; then
            su ${HDFS_SUPERUSER} -c "hdfs dfs -get ${YARN_APP_LOG_DIR_HDFS} ${TEMP_BACKUP_DIR}/${YARN_HISTORICAL_APPLICATION_LOGS_BACKUP_FILE_NAME}"
    	# Cluster is kerberized
    	else
	    # Dowload the logs
            hdfs dfs -get ${YARN_APP_LOG_DIR_HDFS} ${TEMP_BACKUP_DIR}/${YARN_HISTORICAL_APPLICATION_LOGS_BACKUP_FILE_NAME}
   	fi
    fi

    # Create the compressed backup of YARN historical application log files
    if [ "${NAMENODE_SERVER}" = "yes" ]; then
        tar -zcvf ${TEMP_BACKUP_DIR}/${YARN_HISTORICAL_APPLICATION_LOGS_BACKUP_FILE_NAME}.tar.gz -C ${TEMP_BACKUP_DIR} ${YARN_HISTORICAL_APPLICATION_LOGS_BACKUP_FILE_NAME} 
    fi

    # Add YARN historical application logs to zip
    if [ -f "${TEMP_BACKUP_DIR}/${YARN_HISTORICAL_APPLICATION_LOGS_BACKUP_FILE_NAME}.tar.gz" ]; then
        TARS_FOR_ZIP+=("${YARN_HISTORICAL_APPLICATION_LOGS_BACKUP_FILE_NAME}.tar.gz")
    fi
fi

###### Auto-Determine HDP Cluster Name  ######

# Obtain the HDP Cluster from ambari-agent logs
HDP_CLUSTER_NAME="UNKNOWN"
counter=10
if [ -d ${AMBARI_AGENT_LOG_DIR} ]; then
  while [ ${counter} -gt 0 ]
  do
     # Attempt to get the cluster name form the ambari-agent logs
     ambari_hdp_cluster_name=$(grep "u'clusterName':" ${AMBARI_AGENT_LOG_DIR}/ambari-agent.log* | head -1 | sed "s|,|\n|g" | grep "u'clusterName':" | head -1 | cut -d ":" -f 2 | cut -d "'" -f 2)
     if [ -z "${ambari_hdp_cluster_name}" ]; then
         continue
     else
         HDP_CLUSTER_NAME=${ambari_hdp_cluster_name}
         break
     fi

     counter=$(( $counter - 1 ))
     sleep 5
  done
# No ambari-agent on this Host, try getting cluster name from ambari-server
# This option is for an ambari-server running on an edge with no ambari-agent registered
else
  while [ ${counter} -gt 0 ]
  do
    # Attempt to get the cluster name form the ambari-server logs
    ambari_hdp_cluster_name=$(grep "clusterName=" ${AMBARI_SERVER_LOG_DIR}/ambari-server.log* | head -1 | sed "s|,|\n|g" |grep "clusterName=" | head -1 |cut -d "=" -f 2)
    if [ -z "${ambari_hdp_cluster_name}" ]; then
         continue
     else
         HDP_CLUSTER_NAME=${ambari_hdp_cluster_name}
         break
     fi

     counter=$(( $counter - 1 ))
     sleep 5  
   done
fi

###### Create Final Zip File  ######

# Get current directory
current_dir=$(pwd)

# Change to temporary directory
cd ${TEMP_BACKUP_DIR}

# Zip files
zip ${ZIPPED_BACKUP_FILE_NAME} ${TARS_FOR_ZIP[*]}

###### Upload Zip File to AWS S3  ######

# export S3 Credentials
export AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
export AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}

# Load backup to S3
aws s3 cp ${TEMP_BACKUP_DIR}/${ZIPPED_BACKUP_FILE_NAME} s3://${AWS_S3_BUCKET}/${AWS_S3_FOLDER_FOR_BACKUPS}/${HDP_CLUSTER_NAME}/

###### Cleanup  ######

# Change back to saved current directory
cd ${current_dir}

# Cleanup temporary directory
rm -rf ${TEMP_BACKUP_DIR}

# Destory kerberos ticket
if [ "${KERBEROS_ENABLED}" -ne "0" ]; then
    kdestroy
fi

# Disable Debug Mode
set +x

# Exit Cleanly
exit 0 
