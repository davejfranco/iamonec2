#!/bin/bash

#Create by Dave J. Franco <dfranco@groupon.com>

# Installation steps for Ubuntu

# - apt-get update
# - apt-get install jq
# - curl "https://bootstrap.pypa.io/get-pip.py" -o "get-pip.py" && python get-pip.py
# - pip install awscli
# - copy script into ops directory and create cron to execute every 5 mins

# Installation steps for Centos or Amazon
# - yum update
# - yum install jq or wget -O jq https://github.com/stedolan/jq/releases/download/jq-1.5/jq-linux64 && chmod +x jq && mv jq /usr/bin
# - make user pip is installed or curl "https://bootstrap.pypa.io/get-pip.py" -o "get-pip.py" && python get-pip.py
# - make sure awscli pip package is installed
# - copy script into ops directory and create cron to execute every 5 mins
# - create cron: echo '*/2 * * * * root /var/ops/user.sh' >> /etc/crontab

#As this script will be run by cron is to identify the system PATH

Log () {

	LOGFILE=/var/log/qoopit/users.log
	#Make sure this file exits
	touch $LOGFILE
	NOW=$(date +"%Y-%m-%d %H:%M:%S")

	echo "$NOW $1 $2" >> $LOGFILE
}

#Add user and give it sudo powers
CreateUser () {

	useradd -m -s /bin/bash $1
	cat >> /etc/sudoers.d/$1 << EOF
$1 ALL = NOPASSWD: ALL

# User rules
$1 ALL=(ALL) NOPASSWD:ALL

EOF

	#add user .ssh directory
	mkdir /home/$1/.ssh
	touch /home/$1/.ssh/authorized_keys
	chown -R $1:$1 /home/$1/.ssh
	chmod 0700 /home/$1/.ssh
	chmod 0600 /home/$1/.ssh/authorized_keys

}

#Delete User and its sudo powers
DelUser () {

	#Remove user
	userdel -r $1
	#Remove from suduers
	rm -rf /etc/sudoers.d/$1
}

SSHKeys () {

	SSHKEYIDS=$(/opt/qoopit/ops/venv/bin/aws iam list-ssh-public-keys --user-name $1 | jq ."SSHPublicKeys"[]."SSHPublicKeyId" -r)

	if [[ ! -z $SSHKEYIDS ]];
	then
		touch /tmp/$1
		for keyid in $SSHKEYIDS;
		do
			SSHKEY=$(/opt/qoopit/ops/venv/bin/aws iam get-ssh-public-key --user-name $1 --ssh-public-key-id $keyid --encoding SSH | jq ."SSHPublicKey"."SSHPublicKeyBody" -r)
			#SSHKEY=$(echo $SSHKEY | awk -F "\"" '{print $2}')
			grep -q "$SSHKEY" /tmp/$1 || echo "$SSHKEY" >> /tmp/$1
		done
	else
		#if the aren't public keys left authorized_keys in blank
		cp /dev/null /home/$1/.ssh/authorized_keys 2> /dev/null
		if [ $? -eq 0 ]; then
			Log "INFO" "User $1 has not valid ssh keys"
		fi
	fi

	if [ -f /tmp/$1 ]; then
		#If recent generated file is different from the current user's authorized_keys then replace it
		cmp --silent /home/$1/.ssh/authorized_keys /tmp/$1 || mv /tmp/$1 /home/$1/.ssh/authorized_keys 2> /dev/null && \
			chmod 0600 /home/$1/.ssh/authorized_keys && chown -R $1:$1 /home/$1/.ssh \
			Log "INFO" "User $1's ssh key has changed" 2> /dev/null
	fi
	rm /tmp/$1 2>/dev/null
}

#Get my ec2 instance id
EC2ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)

#Know the region you are
REGION=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq .region -r)

#Get the tags I have and find which group is manging me
TAGS=$(/opt/qoopit/ops/venv/bin/aws ec2 describe-instances --instance-ids $EC2ID --region $REGION | jq ."Reservations"[0]."Instances"[0]."Tags")
N_TAGS=$(echo $TAGS | jq '.[] | length' | wc -l)

#Check response before doing anything
if [[ ( -z $EC2ID ) || ( -z $REGION ) || ( -z $TAGS ) ]];
then
	exit 0
fi

#find whos should manage this server
for n in $(seq 0 $N_TAGS); #find a better way to do this
do
	KEY=$(echo $TAGS | jq .[$n]."Key")
	if [[ $KEY == '"ManagedBy"' ]]; then
	    MANAGEDBY=$(echo $TAGS | jq .[$n]."Value" -r)
	    break
	else:
		echo "Unable to find Tag:ManagedBy"
		exit 1
	fi
done

#Get user
USERS=$(/opt/qoopit/ops/venv/bin/aws iam get-group --group-name $MANAGEDBY | jq ."Users"[]."UserName" -r)

#Check if users exists in the server and update ssh key if necessary
for user in $USERS;
do
    echo $user >> /tmp/awsusers
    ret=false
    getent passwd $user > /dev/null 2>&1 && ret=true
    SSHKeys $user
	if $ret; then
       #Check its ssh keys
       SSHKeys $user
	else
		CreateUser $user 2>&1
		if [ $? -eq 0 ]; then
			Log "INFO" "user $user Successfully created"
		else
			Log "CRITICAL" "Unable to add user $1"
		fi
	SSHKeys $user
	fi
done


#Remove old users
for sudoer in $(ls /etc/sudoers.d);
do
	if [[ -z $(cat /tmp/awsusers | grep -o $sudoer) && $sudoer != "cloud-init" && $sudoer != "90-cloud-init-users" ]];
	then
		DelUser $sudoer
		if [ $? -eq 0 ]; then
			Log "INFO" "user $sudoer has been deleted"
		else
			Log "CRITICAL" "Unable to remove $sudoer"
		fi
	fi
done

#rm awsuser tmp file
rm /tmp/awsusers 2> /dev/null
