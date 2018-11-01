# Cloudbreak Recipes

## backup_hdp_logs_s3.sh

1. Searches the HDP base log directory (/var/log) for any directories owned by HDP system groups.
2. Creates a list of all log files that need to be backed up.
3. Adds user specified logs owned by root system group to the list.
4. Tars these logs in the list with the name: hdp-logs.tar.gz
5. Searches for running yarn application logs and adds them to the list.
6. Tars these logs in the list with the name: yarn-running-application-logs.tar.gz
5. Searches for historical yarn application logs and adds them to the list.
6. Tars these logs in the list with the name: yarn-historical-application-logs.tar.gz
7. Zips all tars together as: YYMMDD_HHmmSS-Hostname.zip
8. Installs awscli using pip
9. Copies zip file to s3 using awscli

## Author
Nasheb Ismaily

