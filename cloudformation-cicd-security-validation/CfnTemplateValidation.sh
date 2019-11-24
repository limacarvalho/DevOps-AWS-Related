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