#!/bin/bash

## Author: Nasheb Ismaily
## 
## Description: Searches the HDP base log directory (/var/log) for any directories owned by HDP system groups.
##		Creates a list of all log files that need to be backed up.
##		Adds user specified logs owned by root system group to the list.
##		Tars the logs in the list with the name: hdp-logs.tar.gz
##		Searches for yarn application logs and adds them to the list.
##		Tars the logs in the list with the name: yarn-application-logs.tar.gz
##		Zips both tars together as: YYMMDD_HHmmSS-Hostname.zip
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

# Top level directory to search for HDP logs
HDP_LOG_BASE_DIR=/var/log

# Directory containint ambari agent logs, used to obtain Ambari - HDP Cluster Name
AMBARI_AGENT_LOG_DIR=/var/log/ambari-agent

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

# Temporary directory to store the log backups
TEMP_BACKUP_DIR=/tmp

# Get current data for tar file
DATE=$(date '+%Y%m%d_%H%M%S')

# Get the hostname of the server
HOSTNAME=$(hostname | cut -d "." -f 1)

# HDP logs compressed backup filename
HDP_LOGS_BACKUP_FILE_NAME=hdp-logs

# YARN application compressed backup filename
YARN_APPLICATION_LOGS_BACKUP_FILE_NAME=yarn-application-logs

# Name of the ZIP file contained HDP logs and YARN application logs
ZIPPED_BACKUP_FILE_NAME="${DATE}-${HOSTNAME}.zip"

# List of HDP logs of current host
declare -a HDP_LOGS_FOR_BACKUP

# List of YARN application logs for current host
declare -a YARN_APPLICATION_LOGS_FOR_BACKUP

#########################  Begin  #########################

# Install dependecies
yum -y install tar zip

# Install awscli
pip install awscli

# Obtain list of log directories to backup based on system groups
for system_group in "${HDP_SYSTEM_GROUPS[@]}"
do
   # Skip group if it doesn't exist on the host
   group_count=$(grep -w "${system_group}" /etc/group | wc -l)
   if [ "${group_count}" -eq "0" ]; then
       continue
   fi

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

# Add yarn application logs to backup list
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

# Obtain the HDP Cluster name
HDP_CLUSTER_NAME="UNKNOWN"
counter=10
while [ ${counter} -gt 0 ]
do
   # Attempt to get the cluster name form the ambari-agent logs
   ambari_hdp_cluster_name=$(grep "u'clusterName':" ${AMBARI_AGENT_LOG_DIR}/ambari-agent.log | head -1 | sed "s|,|\n|g" | grep "u'clusterName':" | head -1 | cut -d ":" -f 2 | cut -d "'" -f 2)
   if [ -z "${ambari_hdp_cluster_name}" ]; then
       continue
   else
       HDP_CLUSTER_NAME=${ambari_hdp_cluster_name}
       break
   fi

   counter=$(( $counter - 1 ))
   sleep 5
done

# Create the compressed backup of HDP log files
tar_command=$( IFS=$' '; echo "tar -zcvf ${TEMP_BACKUP_DIR}/${HDP_LOGS_BACKUP_FILE_NAME}.tar.gz --transform 's,^,${HDP_LOGS_BACKUP_FILE_NAME}/,' -C ${HDP_LOG_BASE_DIR} ${HDP_LOGS_FOR_BACKUP[*]}" )
eval ${tar_command}

# Create the compressed backup of YARN application log files
if [ ${#YARN_APPLICATION_LOGS_FOR_BACKUP[@]} -ne 0 ]; then
    tar_command=$( IFS=$' '; echo "tar -zcvf ${TEMP_BACKUP_DIR}/${YARN_APPLICATION_LOGS_BACKUP_FILE_NAME}.tar.gz --transform 's,^,${YARN_APPLICATION_LOGS_BACKUP_FILE_NAME}/,' -C ${YARN_APPLICATION_LOGS_DIR} ${YARN_APPLICATION_LOGS_FOR_BACKUP[*]}" )
    eval ${tar_command}
fi

# Get current directory
current_dir=$(pwd)

# Zip only the HDP logs
if [ ${#YARN_APPLICATION_LOGS_FOR_BACKUP[@]} -eq 0 ]; then
   cd ${TEMP_BACKUP_DIR} && zip ${ZIPPED_BACKUP_FILE_NAME} ${HDP_LOGS_BACKUP_FILE_NAME}.tar.gz
# Zip the HDP logs and YARN application logs
else
    cd ${TEMP_BACKUP_DIR} && zip ${ZIPPED_BACKUP_FILE_NAME} ${HDP_LOGS_BACKUP_FILE_NAME}.tar.gz ${YARN_APPLICATION_LOGS_BACKUP_FILE_NAME}.tar.gz
fi

# Change back to saved current directory
cd ${current_dir}

# export S3 Credentials
export AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
export AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}

# Load backup to S3
aws s3 cp ${TEMP_BACKUP_DIR}/${ZIPPED_BACKUP_FILE_NAME} s3://${AWS_S3_BUCKET}/${AWS_S3_FOLDER_FOR_BACKUPS}/${HDP_CLUSTER_NAME}/

# Cleanup
#rm -rf ${TEMP_BACKUP_DIR}/${ZIPPED_BACKUP_FILE_NAME} ${TEMP_BACKUP_DIR}/${HDP_LOGS_BACKUP_FILE_NAME}.tar.gz ${TEMP_BACKUP_DIR}/${YARN_APPLICATION_LOGS_BACKUP_FILE_NAME}.tar.gz

# Disable Debug Mode
set +x

# Exit Cleanly
exit 0 
