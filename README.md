# User management shell script

## Back history
This script was created in a rush as a temporary solution to manage users based on the IAM users in the AWS environment.

## How this works?

On IAM you will have to create groups of users, each users should upload their ssh public key in the "Security credential" section in "SSH keys for AWS CodeCommit" part. 

The script should be deploy to the instances you want to manage, also those instances will require an additional tag "ManagedBy" that should match with the name of a particular IAM group. The script will read the ManagedBy tag and will look into IAM and if there is a match will create all the users in the group and will add theirs ssh publick keys... cool right?

Optional:
You can create a cronjob to run the script every 10min or so in order to detect changes in the group.



