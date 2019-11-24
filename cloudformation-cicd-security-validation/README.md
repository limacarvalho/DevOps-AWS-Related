## The problem:

I use the cfn-nag tool to verify all the CloudFormation templates that we ship to production, this means that as part of our Codepipeline we have a build step in-place (could be an AWS Lambda or a Codebuild) which will run the security validation.



**I like some efficiency 😎**



* The Build execution should be fast as possible, so the idea is to only run the files from the last commit pushed instead of going through the complete repo structure every time (which can become an issue when dealing with hundreds of CloudFormation templates). 
* We should also skip files that are not either .YAML or .YML (we never use JSON for our CF templates).
* We should be able to run a complete scan whenever we need.
* An error in one of the templates should fail the Codepipeline execution.

## The solution:


Taking into consideration all the requirements we decided to use a Codebuild for it, giving us more flexibility, easiness to implement and visualization if something happens. 

*Note: As an alternative, the cfn-nag is also available from the AWS Lambda public serverless app repository, you can integrate easily the cfn-nag-pipeline function into your Codepipeline.*



## My use case:


I use Codecommit as my Codepipeline source, but my Bash script also supports any git-like repo, as long as you choose to pass the .git files to Codebuild. By getting the list of the CF files from the last commit we can then run cfn-nag agaist thiose files only.


![CodebuildSettings](../assets/images/codebuild-settings.jpg "eg. Codebuild settings")


**In a nutshell:**

* The cfn-nag runs in a Codebuild (right after the Codepipeline source stage).
* It validates all the CloudFormation files (from the last commit pushed, but also supports a "full scan" bypassing the argument to the Codebuild buildspec file or when you run the Codebuild from the 1st time).
* Does also an optional cfn-lint Syntax validation.
* If a CloudFormation template contains too permissive IAM policies, Security Group rules, NACLs, etc the Codebuild process will fail and consequently, the Codepipeline interrupts the normal deployment.



## Example of successful/validated build:


![CodebuildLogInfo](../assets/images/codebuild-loginfo.jpg "eg. Information of latest git commit before starting the validation")



![CodebuildSuccess](../assets/images/codebuild-success.jpg "eg. Output of successful validation")


## Example of a failed build job:



![CodebuildFailure](../assets/images/codebuild-failure.jpg "eg. Output of failed validation")


---

***buildspec.yml***

```yaml:
version: 0.2
phases:
  install:
    runtime-versions:
        ruby: 2.6    
    commands:
    - pip3 install awscli --upgrade --quiet
    - pip3 install cfn-lint --quiet
    - aws --version              
    - yum install jq git -y -q
    - gem install cfn-nag
    - cfn_nag_rules # Show all cfn_nag_rules that will be used in the scan
  build:
    commands:
    - scriptToExecute=`find $(pwd)/ \( -name "CfnTemplateValidation.sh" \) `
    - chmod +x "$scriptToExecute"
    - bash "$scriptToExecute" --full_scan no --codecommit-repository_name NAME-OF-YOUR-CODECOMMIT-REPO --codebuild_project_name NAME-OF-CODEBUILD-PROJECT
artifacts:
  files: '**/*'
```
</br>

***CfnTemplateValidation.sh***

```Bash:
#!/bin/bash
#
# Copyright (c) globaldatanet.
#    All rights reserved.
#
# Any use of this file as part of a software system by non Copyright holders
# is subject to license terms.
#
# Cloud Formation syntax (awscli) and security validation (cfn-nag). Supports Codecommit repositories and other git-like repos.

fullScan=""
repositoryName=""
codebuildProjectName=""

while [ "$1" != "" ]; do
    case $1 in
        -fs | --full_scan )   shift
                                fullScan=$1
                                ;;
        -cn | --codecommit-repository_name )   shift
                                repositoryName=$1
                                ;;
        -cpn | --codebuild_project_name )  shift
                                codebuildProjectName=$1
                                ;;
    esac
    shift
done

# Verify if previous builds executions exist. Equals to 1 means that is the first execution for the CodeBuild Project.
numPreviousCodeBuildExec=`aws codebuild list-builds --output text | grep "$(echo $codebuildProjectName):" | wc -l `

# Based on the existence or not of previous build executions, the script will run the validation for all YAML files or just the ones related to the latest git commit (Supports fetching repository commits from .git folders and aws codecommit API)
allAccountsDirs=(`ls -ad $(pwd)/`)
existingGitDirs=(`find $(echo $allAccountsDirs)/ \( -name '*.git' \) `)
existingGitDirs=(`echo ${existingGitDirs[0]}`)
function getListOfFiles() {
    if [[ "$numPreviousCodeBuildExec" -gt 1 ]]; then
        if [[ ! -z "$repositoryName" ]]; then
            repoLastCommitId=`aws codecommit get-branch --repository-name $(echo $repositoryName) --branch-name master --output json | jq -r '.branch.commitId'`
            repoLastCommitInfo=`aws codecommit get-commit --repository-name $(echo $repositoryName) --commit-id $(echo $repoLastCommitId) --output json`            
            repoParentOfLastCommitId=`echo $repoLastCommitInfo | tr '\r\n' ' ' | jq -r '.commit.parents | .[]' | head -n 1`
            listOfFilesToScan=`aws codecommit get-differences --repository-name $(echo $repositoryName) --before-commit-specifier $(echo $repoLastCommitId) --after-commit-specifier $(echo $repoParentOfLastCommitId) --output json | jq -r '.differences | .[] | .beforeBlob.path' | grep -e ".yml" -e ".yaml"`
            echo ""
            echo "The number of CloudFormation YAML files in the last commit = $(echo $listOfFilesToScan | grep -e ".yml" -e ".yaml" | wc -l)"
            echo "Last committed changes done by: $(echo $repoLastCommitInfo | tr '\r\n' ' ' | jq -r '.commit.author.name')"
            echo "Email of the User: $(echo $repoLastCommitInfo | tr '\r\n' ' ' | jq -r '.commit.author.email')"
            echo "Git commit ID: $(echo $repoLastCommitInfo | tr '\r\n' ' ' | jq -r '.commit.commitId')"
            echo "Git commit message: $(echo $repoLastCommitInfo | tr '\r\n' ' ' | jq -r '.commit.message')"
            echo ""
        else
            cd $existingGitDirs
            listOfFilesToScan=`git show --name-only --oneline HEAD | grep -e ".yaml" -e ".yml" `
            echo ""
            echo "The number of CloudFormation YAML files in the last commit = $(echo $listOfFilesToScan | grep -e ".yml" -e ".yaml" | wc -l)"
            echo "Last committed changes done by $(git show | head -n 10 | grep Author)"
            echo "Git $(git show | head -n 10 | grep commit)"
            cd $allAccountsDirs
            echo ""
        fi
    else
        listOfFilesToScan=`find $(echo ${allAccountsDirs[@]}) \( -name '*.yml' -o -name '*.yaml' \) `
    fi
}

function usage
{
    echo "usage: CfnTemplateValidation.sh [-h] --full_scan YES\NO
                                      --codecommit-repository_name REPOSITORY_NAME
                                      --codebuild_project_name CODEBUILD_PROJECT_NAME"
}

# Checks if a full scan option evaluates to 'yes' otherwise calls the 'getListOfFiles' function. When another option or none is specified prints help message.
if [[ "$fullScan" = "yes" ]]; then
    listOfFilesToScan=`find $(echo ${allAccountsDirs[@]}) \( -name '*.yml' -o -name '*.yaml' \) `
elif [[ "$fullScan" = "no" ]]; then
    getListOfFiles
else
    usage
    exit
fi

# Count the number of files to scan
howmany() { echo $#; }
numOfFilesValidated=`howmany $listOfFilesToScan`   

# Start the Syntax validation for the CloudFormation files (Using python cfn-lint)
echo ""
echo "=========================================== Syntax validation started =============================================================="
cfSyntaxLogFile="cf-syntax-validation-output"
numOfFailures=0
numOfValidatedFiles=0
for file in $listOfFilesToScan; do
    if [[ $(cfn-lint -t "$file" |& tee -a $cfSyntaxLogFile) == "" ]]; then
        echo "INFO: Syntax validation of template $file: SUCCESS"
        ((numOfValidatedFiles++))
    else
        echo "ERROR: Syntax validation of template $file: FAILURE"
        ((numOfFailures++))
    fi
done
if [ $numOfFailures -gt 0 ]; then
    cat $cfSyntaxLogFile
    echo "ERROR: Syntax validation for templates failed. Please check the above output for details."
    echo "ERROR: Syntax Validation Result: Total: $numOfFilesValidated; Success: $numOfValidatedFiles; Failure: $numOfFailures"
else
    echo "INFO: Syntax validation for templates succeeded."
    echo "INFO: Syntax Validation Result: Total: $numOfFilesValidated; Success: $numOfValidatedFiles; Failure: $numOfFailures"
fi
echo ""
echo "=========================================== Syntax validation finished =============================================================="
echo ""
sleep 2s

# Start the Security validation for the CloudFormation files
echo "=========================================== cfn-nag validation started =============================================================="
cfnLogFile="cfn-nag-scan-output"
numOfCfnFailures=0
numOfCfnValidatedFiles=0
for file in $listOfFilesToScan; do
    if [[ $(cfn_nag_scan -n --input-path "$file" |& tee -a $cfnLogFile) = *FAIL* ]]; then
        echo "ERROR: Security validation of template $file: FAILURE"
        ((numOfCfnFailures++))
    else
        echo "INFO: Security validation of template $file: SUCCESS"
        ((numOfCfnValidatedFiles++))
    fi
done
if [ $numOfCfnFailures -gt 0 ]; then
    cat $cfnLogFile
    echo "ERROR: Security validation for templates failed. Please check the above output for details."
    echo "ERROR: Security Validation Result: Total: $numOfFilesValidated; Success: $numOfCfnValidatedFiles; Failure: $numOfCfnFailures"
    echo "!!! ABORTING BUILD PROCESS !!!"
    exit 1
else
    echo "INFO: Security validation for templates succeeded."
    echo "INFO: Security Validation Result: Total: $numOfFilesValidated; Success: $numOfCfnValidatedFiles; Failure: $numOfCfnFailures"
fi
echo "=========================================== cfn-nag validation finished =============================================================="
echo ""
```
</br>

