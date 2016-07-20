#!/usr/bin/env bash

# http://redsymbol.net/articles/unofficial-bash-strict-mode/
set -euo pipefail
IFS=$'\n\t'

####################################################
# Defaults
####################################################
BAMBOO_EC2_PROPS='/home/bamboo/.ec2/ec2.properties'
BAMBOO_JDK_8_STRING='JDK-1.8'
BAMBOO_JDK_DEFAULT='JDK-1.7'
GRADLE_WRAPPER='./gradlew'
GRADLE_TMP_BASE='/tmp/gradlehome'
buildProperties="src/build/ant/build.properties"
PARQUET='-Duse-parquet-storage=true'

# util to get a green build name
getGB() { echo "Datameer - Green Builds - $@ - job"; }
getIB() { echo "Datameer - Info Builds - $@ - job"; }
declare -A jobNames

# Green Builds
jobNames[compile]="$(getGB 'Compile Datameer Distributions')"
jobNames[findbugs]="$(getGB 'Findbugs')"
jobNames[unitTests]="$(getGB 'Unit Tests')"
jobNames[itTests]="$(getGB 'Integration Tests')"
jobNames[itTestsLong]="$(getGB 'Long Running Integration Tests')"
jobNames[jsSpecs]="$(getGB 'Javascript Specs')"
jobNames[embeddedCluster]="$(getGB 'Embedded Cluster')"
jobNames[efwLocal]="$(getGB 'EFW Local')"
jobNames[efwSmallJob]="$(getGB 'EFW Small Job')"
jobNames[efwSmart]="$(getGB 'EFW Smart')"
jobNames[efwSparkClient]="$(getGB 'EFW Spark Client')"
jobNames[efwSparkCluster]="$(getGB 'EFW Spark Cluster')"
jobNames[efwSparkSX]="$(getGB 'EFW Spark SX')"
jobNames[efwTez]="$(getGB 'EFW Tez')"
jobNames[findbugs18]="$(getGB 'Findbugs (JDK-1.8)')"
jobNames[unitTests18]="$(getGB 'Unit Tests (JDK-1.8)')"
jobNames[itTests18]="$(getGB 'Integration Tests (JDK-1.8)')"
jobNames[localDB]="$(getGB 'Local Database Tests')"
jobNames[remoteDB]="$(getGB 'Remote Database Tests')"

# Info Builds
jobNames[efwSparkClientFull]="$(getIB 'EFW Spark Client (full)')"
jobNames[efwSparkClusterFull]="$(getIB 'EFW Spark Cluster (full)')"
jobNames[efwTezFull]="$(getIB 'EFW Tez (full)')"
jobNames[yarnFull]="$(getIB 'YARN (full)')"
jobNames[itTestsLong18]="$(getIB 'Long Running Integration Tests (JDK-1.8)')"
jobNames[psfUnitTests]="$(getGB 'Parquet Unit Tests')"
jobNames[psfItTests]="$(getGB 'Parquet Integration Tests')"
jobNames[psfItTestsLong]="$(getGB 'Parquet Long Running Integration Tests')"
jobNames[psfEmbeddedCluster]="$(getGB 'Parquet Embedded Cluster')"

usage()
{
cat << EOF
usage: $0 [OPTIONS]

This script executes a job step according to the job name.

OPTIONS:
   -h      Show this message
   -v      Verbose
   -j <j>  JobName
   -l      List possible job names
   -L      List possible job names and dry-run
   -d      Dry run
EOF
}

# Default values
VERBOSE=0
DRYRUN=0

die() {
    (>&2 echo -e "RUN-TASK - ERROR: $@")
    exit 1
}

echoInfo() {
    echo -e "RUN-TASK - INFO:  $@"
}

echoDebug() {
    if [ $VERBOSE -eq 1 ]; then
        echo -e "RUN-TASK - DEBUG: $@"
    fi
}

copyEc2Properties() {
    if [ -e "$BAMBOO_EC2_PROPS" ]; then
        exec cp "$BAMBOO_EC2_PROPS" "$bamboo_build_working_directory/modules/dap-common/src/it/resources/ec2.properties"
    fi
}

listJobs() {
    printf "%-25s   %s\n" "SHORTNAME" "LONGNAME"
    for i in "${!jobNames[@]}"; do
        printf "%-25s   %s\n" "$i" "${jobNames[$i]}"
    done
}

listJobsAndDryRun() {
    printf "%-25s   %s\n" "SHORTNAME" "LONGNAME"
    for i in "${!jobNames[@]}"; do
        printf "%-25s   %s\n" "$i" "${jobNames[$i]}"
        setDryRun && setVerbose
        runJob $i
    done
}

atLeastVersion() {
    local atLeastRaw=$1
    local atLeast=$(echo $atLeastRaw | sed 's/\(\.0\)*$//')
    echoDebug "At least version: '$atLeast' (normalised from $atLeastRaw)"
    [ ! -e $buildProperties ] && die "Cannot find file '$buildProperties'"
    local versionRaw="$(grep -oE "^version=.*" $buildProperties | cut -f2 -d'=')"
    local version=$(echo $versionRaw | sed 's/\(\.0\)*$//')
    echoInfo "Found DAP version: '$version' (normalised from $versionRaw). Comparing to version $atLeast"
    local latestVersion=$(echo -e "$atLeast\n$version" | sort -t '.' -k 1,1 -k 2,2 -k 3,3 -k 4,4 -g | tail -n 1)
    echoDebug "Latest version determined as: '$latestVersion'"
    [ "$latestVersion" == "$version" ]
}

checkJdk() {
    local version execProgram expectedVersion
    expectedVersion=$1 || die "No expectedVersion parameter passed."
    execProgram=$(which java || die "No java found on PATH")
    echoDebug "Using $execProgram"
    case ${#expectedVersion} in
        2) version=$(java -version 2>&1 | grep "^.*\sversion" | sed 's/.*version "\([0-9]*\)\.\([0-9]*\)\..*"/\1\2/; 1q');;
        3) version=$(java -version 2>&1 | grep "^.*\sversion" | sed 's/.*version "\([0-9]*\)\.\([0-9]*\)\.\([0-9]*\).*"/\1\2\3/; 1q');;
        *) die "You must specify a version between 2 and 3 digits."
    esac
    echoInfo "Found java version: $version"
    if [ $expectedVersion -ne $version ]; then
        local errorMsg="Wrong java version found. Found '$version', expected '$expectedVersion'"
        if [ $DRYRUN  -eq 1 ]; then
            echoInfo "DRYRUN: $errorMsg"
        else
            die "$errorMsg"
        fi
     fi
}

checkAnt() {
    local version execProgram expectedVersion
    expectedVersion=$1 || die "No expectedVersion parameter passed."
    execProgram=$(which ant || die "No ant found on PATH")
    echoDebug "Using $execProgram"
    case ${#expectedVersion} in
        2) version=$(ant -version 2>&1 | grep "^.*\sversion" | sed 's/.*version \([0-9]*\)\.\([0-9]*\)\..*/\1\2/; 1q');;
        3) version=$(ant -version 2>&1 | grep "^.*\sversion" | sed 's/.*version \([0-9]*\)\.\([0-9]*\)\.\([0-9]*\) .*/\1\2\3/; 1q');;
        *) die "You must specify a version between 2 and 3 digits."
    esac
    echoInfo "Found ant version: $version"
    if [ $expectedVersion -ne $version ]; then
        local errorMsg="Wrong ant version found. Found '$version', expected '$expectedVersion'"
        if [ $DRYRUN  -eq 1 ]; then
            echoInfo "DRYRUN: $errorMsg"
        else
            die "$errorMsg"
        fi
     fi
}

onBamboo() {
    [[ "$USER" == "bamboo" ]]
}

setJdk() {
    if onBamboo; then
        local jdkDir
        case "$1" in
            17) jdkDir="$bamboo_capability_system_jdk_JDK_1_7";;
            18) jdkDir="$bamboo_capability_system_jdk_JDK_1_8";;
            *) die "Unexpected JDK Version '$1'";;
        esac
        [ -e "$jdkDir" ] || die "Directory '$jdkDir' not found."
        export JAVA_HOME="$jdkDir"
        export PATH="$jdkDir/bin:$PATH"
    else
        echoInfo "Not on CI Server - Not setting JDK."
    fi
    checkJdk $1
}

setAnt() {
    if onBamboo; then
        local antDir
        case "$1" in
            18) antDir="$bamboo_capability_system_builder_ant_Ant_1_8_4";;
            19) antDir="$bamboo_capability_system_builder_ant_Ant_1_9_4";;
            *) die "Unexpected ANT Version '$1'";;
        esac
        [ -e "$antDir" ] || die "Directory '$antDir' not found."
        export ANT_HOME="$antDir"
        export PATH="$antDir/bin:$PATH"
    else
        echoInfo "Not on CI Server - Not setting ANT."
    fi
    checkAnt $1
}

setEnvVars() {
    for i in "${!myEnvVariables[@]}"
    do
        echoInfo "Exporting... $i=${myEnvVariables[$i]}"
        exec export $i="'${myEnvVariables[$i]}'"
    done
}

exec() {
    if [ $DRYRUN  -eq 1 ]; then
        echoInfo "DRYRUN: $@"
        return 0
    fi
    eval "$@"
}

# environment variables need to be set before
runAnt() {
    local jdkVersion=$1
    local antVersion=$2
    local target=$3
    setJdk $jdkVersion
    setAnt $antVersion
    cmd="ant $target"
    echoInfo "Running... $cmd"
    exec $cmd
}

# environment variables need to be set before
runGradle() {
    [ -x $GRADLE_WRAPPER ] || die "File '$GRADLE_WRAPPER' either non-existent or not executable."
    local jdkVersion=$1
    local antVersion=$2
    local target=$3
    setJdk $jdkVersion
    setAnt $antVersion
    cmd="$GRADLE_WRAPPER $target"
    echoInfo "Running... $cmd"
    exec $cmd
}

getKey() {
    for i in "${!jobNames[@]}"; do
        if [ "$1" == "$i" ] || [ "$1" == "${jobNames[$i]}" ] ; then
              echo "$i"
        fi
    done
}

notImpemented() {
	if [ $DRYRUN  -eq 1 ]; then
		echoInfo "DRYRUN: Job not yet implemented"
	else
		die "Not yet implemented" # TODO: what to do here?
	fi
}

getAntOptsBasic() {
	local ANT_OPTS=''
	ANT_OPTS="$ANT_OPTS -Dhalt.on.failure=false -DshowOutput=false"
	ANT_OPTS="$ANT_OPTS -Xmx${1:-512}m -XX:MaxPermSize=256m"
	echo "$ANT_OPTS"
}

getAntOptsBasicWithPlanName() {
	local ANT_OPTS
	ANT_OPTS="$(getAntOptsBasic $*)"
	ANT_OPTS="$ANT_OPTS $(getAntOptPlanName)"
	echo "$ANT_OPTS"
}

getAntOptsEfwLocal() {
	local ANT_OPTS=''
	ANT_OPTS="$ANT_OPTS -Dhalt.on.failure=false -DshowOutput=false"
	ANT_OPTS="$ANT_OPTS -Xmx2048m"
	ANT_OPTS="$ANT_OPTS -Dtest.groups=${2:-execution_framework}"
	ANT_OPTS="$ANT_OPTS -Dexecution-framework=$1"
	echo "$ANT_OPTS"
}

getAntOptsEfw() {
	local ANT_OPTS=''
	ANT_OPTS="$(getAntOptsEfwLocal $*)"
	ANT_OPTS="$ANT_OPTS -Dhadoop.dist=cdh-5.4.2-mr2"
	ANT_OPTS="$ANT_OPTS -Dtest.cluster=ec2"
	ANT_OPTS="$ANT_OPTS $(getAntOptPlanName)"
	echo "$ANT_OPTS"
}

getAntOptPlanName() {
    if onBamboo; then
        echo "-Dplan.name=${bamboo_buildResultKey}-${bamboo_repository_branch_name}"
    else
        echo "-Dplan.name=${bamboo_buildResultKey:-dummyKey}-${bamboo_repository_branch_name:-dummyBranch}"
    fi
}

runJob() {
    # TODO: why 1024m for some jobs and only 512m for others?

    local jobInQuestion="${1:-${bamboo_buildPlanName:-}}"
    [ -z "$jobInQuestion" ] && die "Neither bamboo_buildPlanName variable nor input argument passed."
    local shortName=$(getKey "$jobInQuestion")
    [ -n "$shortName" ] || die "Could not find '$jobInQuestion' in job list. Check the supported job list."
    echo "Looking for '$jobInQuestion',  with shortName '$shortName'"

	local -A myEnvVariables # fresh set of envVars to fill on a per job basis
	local ANT_OPTS=''
    case "$shortName" in

        # jobNames[compile]="$(getGB 'Compile Datameer Distributions')"
        'compile')
            echoInfo "Running...$jobInQuestion"
            if atLeastVersion 6; then
                gradleTmpDir=$GRADLE_TMP_BASE/${bamboo_buildKey:-local-run}
                exec mkdir -pv $gradleTmpDir
                runGradle 17 19 "onAllVersions -i -Ptarget=it-jar --gradle-user-home $gradleTmpDir"
                runGradle 17 19 "onAllVersions -i -Ptarget=job-jar --gradle-user-home $gradleTmpDir"
            else
                myEnvVariables[ANT_OPTS]="$(getAntOptsBasic)"
				setEnvVars
                runAnt 17 19 'clean-all it-jar job-jar'
            fi
            ;;

        # jobNames[findbugs]="$(getGB 'Findbugs')"
        'findbugs')
            echoInfo "Running...$jobInQuestion"
            if atLeastVersion 6; then
                runGradle 17 19 'findbugsMain'
            else
				myEnvVariables[ANT_OPTS]="$(getAntOptsBasic)"
				setEnvVars
                runAnt 17 19 'clean-all findbugs-core findbugs-plugins'
            fi
            ;;

        # jobNames[unitTests]="$(getGB 'Unit Tests')"
        'unitTests')
            echoInfo "Running...$jobInQuestion"
            if atLeastVersion 6; then
                runGradle 17 19 'test'
            else
				myEnvVariables[ANT_OPTS]="$(getAntOptsBasic)"
				setEnvVars
                runAnt 17 19 "clean-all unit"
            fi
            ;;

        # jobNames[itTests]="$(getGB 'Integration Tests')"
        'itTests')
            echoInfo "Running...$jobInQuestion"
            if atLeastVersion 9.2; then
				notImpemented
            else
                copyEc2Properties
				myEnvVariables[ANT_OPTS]="$(getAntOptsBasic 1024)"
				setEnvVars
                runAnt 17 19 "clean-all download-ec2-static-property it"
            fi
            ;;

        # jobNames[itTestsLong]="$(getGB 'Long Running Integration Tests')"
        'itTestsLong')
            echoInfo "Running...$jobInQuestion"
            if atLeastVersion 9.2; then
				notImpemented
            else
                copyEc2Properties
				myEnvVariables[ANT_OPTS]="$(getAntOptsBasic)"
				setEnvVars
                runAnt 17 19 "clean-all download-ec2-static-property it-long"
            fi
            ;;

        # jobNames[jsSpecs]="$(getGB 'Javascript Specs')"
        'jsSpecs')
			echoInfo "Running...$jobInQuestion"
            if atLeastVersion 6; then
                exec cd modules/dap-conductor
                exec npm test
            else
                copyEc2Properties
				myEnvVariables[ANT_OPTS]="$(getAntOptsBasic)"
                setEnvVars
                runAnt 17 19 "clean-all specs"
            fi
            ;;

        # jobNames[localDB]="$(getGB 'Local Database Tests')"
        'localDB')
            echoInfo "Running...$jobInQuestion"
            if atLeastVersion 9.2; then
				notImpemented
            else
                copyEc2Properties
				myEnvVariables[ANT_OPTS]="$(getAntOptsBasicWithPlanName 1024)"
                setEnvVars
                runAnt 17 19 "clean-all it-db-netezza"
            fi
            ;;

        # jobNames[remoteDB]="$(getGB 'Remote Database Tests')"
        'remoteDB')
            echoInfo "Running...$jobInQuestion"
            if atLeastVersion 9.2; then
				notImpemented
            else
                copyEc2Properties
				myEnvVariables[ANT_OPTS]="$(getAntOptsBasicWithPlanName 1024)"
                setEnvVars
                runAnt 17 19 "clean-all download-ec2-static-property it-external-resources-managed"
            fi
            ;;

        # jobNames[clusterTests]="$(getGB 'Cluster Tests')"
        'embeddedCluster')
            echoInfo "Running...$jobInQuestion"
            if atLeastVersion 9.2; then
				notImpemented
            else
                copyEc2Properties
				ANT_OPTS="$(getAntOptsBasic 1024)"
				ANT_OPTS="$ANT_OPTS -Dtest.groups=cluster"
				myEnvVariables[ANT_OPTS]="$ANT_OPTS"
                setEnvVars
                runAnt 17 19 "clean-all download-ec2-static-property it"
            fi
            ;;

        # jobNames[efwLocal]="$(getGB 'EFW Local')"
        'efwLocal')
            echoInfo "Running...$jobInQuestion"
            if atLeastVersion 9.2; then
				notImpemented
            else
                copyEc2Properties
				myEnvVariables[ANT_OPTS]="$(getAntOptsEfwLocal Local)"
                setEnvVars
                runAnt 17 19 "clean-all download-ec2-static-property it"
            fi
            ;;

        # jobNames[efwSmallJob]="$(getGB 'EFW Small Job')"
        'efwSmallJob')
            echoInfo "Running...$jobInQuestion"
            if atLeastVersion 9.2; then
				notImpemented
            else
                copyEc2Properties
				myEnvVariables[ANT_OPTS]="$(getAntOptsEfw SmallJob)"
                setEnvVars
                runAnt 17 19 "clean-all download-ec2-static-property unit it-ec2-managed"
            fi
            ;;

        # jobNames[efwSmart]="$(getGB 'EFW Smart')"
        'efwSmart')
            echoInfo "Running...$jobInQuestion"
            if atLeastVersion 9.2; then
				notImpemented
            else
                copyEc2Properties
				myEnvVariables[ANT_OPTS]=$(getAntOptsEfw Smart)
                setEnvVars
                runAnt 17 19 "clean-all download-ec2-static-property unit it-ec2-managed"
            fi
            ;;

        # jobNames[efwSparkClient]="$(getGB 'EFW Spark Client')"
        'efwSparkClient')
            echoInfo "Running...$jobInQuestion"
            if atLeastVersion 9.2; then
				notImpemented
            else
                copyEc2Properties
				ANT_OPTS=$(getAntOptsEfw SparkClient)
                setEnvVars
                runAnt 17 19 "clean-all download-ec2-static-property unit it-ec2-managed"
            fi
            ;;

        # jobNames[efwSparkCluster]="$(getGB 'EFW Spark Cluster')"
        'efwSparkCluster')
            echoInfo "Running...$jobInQuestion"
            if atLeastVersion 9.2; then
				notImpemented
            else
                copyEc2Properties
				myEnvVariables[ANT_OPTS]=$(getAntOptsEfw SparkCluster)
                setEnvVars
                runAnt 17 19 "clean-all download-ec2-static-property unit it-ec2-managed"
            fi
            ;;

        # jobNames[efwSparkSX]="$(getGB 'EFW Spark SX')"
        'efwSparkSX')
            echoInfo "Running...$jobInQuestion"
            if atLeastVersion 9.2; then
				notImpemented
            else
                copyEc2Properties
				myEnvVariables[ANT_OPTS]=$(getAntOptsEfw SparkSX)
                setEnvVars
                runAnt 17 19 "clean-all download-ec2-static-property unit it-ec2-managed"
            fi
            ;;

        # jobNames[efwTez]="$(getGB 'EFW Tez')"
        'efwTez')
            echoInfo "Running...$jobInQuestion"
            if atLeastVersion 9.2; then
				notImpemented
            else
                copyEc2Properties
				myEnvVariables[ANT_OPTS]=$(getAntOptsEfw Tez dist_sanity)
                setEnvVars
                runAnt 17 19 "clean-all download-ec2-static-property unit it-ec2-managed"
            fi
            ;;

        # jobNames[findbugs18]="$(getGB 'Findbugs (JDK-1.8)')"
        'findbugs18')
            echoInfo "Running...$jobInQuestion"
            if atLeastVersion 6.2; then
                runGradle 18 19 findbugsMain
            else
				myEnvVariables[ANT_OPTS]="$(getAntOptsBasic)"
                setEnvVars
                runAnt 18 19 "clean-all findbugs-core findbugs-plugins"
            fi
            ;;

        # jobNames[unitTests18]="$(getGB 'Unit Tests (JDK-1.8)')"
        'unitTests18')
            echoInfo "Running...$jobInQuestion"
            if atLeastVersion 6.2; then
                runGradle 18 19 test
            else
				myEnvVariables[ANT_OPTS]="$(getAntOptsBasic)"
                setEnvVars
                runAnt 18 19 "clean-all unit"
            fi
            ;;

        # jobNames[itTests18]="$(getGB 'Integration Tests (JDK-1.8)')"
        'itTests18')
            echoInfo "Running...$jobInQuestion"
            if atLeastVersion 6.2; then
                runGradle 18 19 it
            else
                copyEc2Properties
				myEnvVariables[ANT_OPTS]="$(getAntOptsBasic 1024)"
                setEnvVars
                runAnt 18 19 "clean-all download-ec2-static-property it"
            fi
            ;;

		# jobNames[efwSparkClientFull]="$(getIB 'EFW Spark Client (full)')"
		'efwSparkClientFull')
            echoInfo "Running...$jobInQuestion"
            if atLeastVersion 9.2; then
				notImpemented
            else
                copyEc2Properties
				ANT_OPTS="$(getAntOptsEfw SparkClient cluster,dist_sanity)"
				ANT_OPTS="$ANT_OPTS -DinstanceType=m3.large"
				myEnvVariables[ANT_OPTS]="$ANT_OPTS"
                setEnvVars
                runAnt 17 19 "clean-all download-ec2-static-property unit it-ec2-managed"
            fi
            ;;

		# jobNames[efwSparkClusterFull]="$(getIB 'EFW Spark Cluster (full)')"
		'efwSparkClusterFull')
            echoInfo "Running...$jobInQuestion"
            if atLeastVersion 9.2; then
				notImpemented
            else
                copyEc2Properties
				ANT_OPTS="$(getAntOptsEfw SparkCluster cluster,dist_sanity)"
				ANT_OPTS="$ANT_OPTS -DinstanceType=m3.large"
				ANT_OPTS="$ANT_OPTS -Dspark.thrift=true"
				myEnvVariables[ANT_OPTS]="$ANT_OPTS"
                setEnvVars
                runAnt 17 19 "clean-all download-ec2-static-property unit it-ec2-managed"
            fi
            ;;

		# jobNames[efwTezFull]="$(getIB 'EFW Tez (full)')"

		'efwTezFull')
            echoInfo "Running...$jobInQuestion"
            if atLeastVersion 9.2; then
				notImpemented
            else
				copyEc2Properties
				ANT_OPTS="$(getAntOptsEfw Tez cluster,dist_sanity)"
				myEnvVariables[ANT_OPTS]="$ANT_OPTS"
                setEnvVars
                runAnt 17 19 "clean-all download-ec2-static-property it-ec2-managed"
				# TODO: why no unit test? (comparing to e.g. efwSparkClientFull)
            fi
            ;;

		# jobNames[yarnFull]="$(getIB 'YARN (full)')"
		'yarnFull')
            echoInfo "Running...$jobInQuestion"
            if atLeastVersion 9.2; then
				notImpemented
            else
                copyEc2Properties
				myEnvVariables[ANT_OPTS]="$(getAntOptsBasic 1024)"
                setEnvVars
                runAnt 17 19 "clean-all download-ec2-static-property it"
            fi
            ;;

		# jobNames[itTestsLong18]="$(getIB 'Long Running Integration Tests (JDK-1.8)')"
		'itTestsLong18')
            echoInfo "Running...$jobInQuestion"
            if atLeastVersion 9.2; then
				notImpemented
            else
                copyEc2Properties
				myEnvVariables[ANT_OPTS]="$(getAntOptsBasic)"
                setEnvVars
                runAnt 18 19 "clean-all download-ec2-static-property it-long"
            fi
            ;;

		# jobNames[psfUnitTests]="$(getGB 'Parquet Unit Tests')"
		'psfUnitTests')
            echoInfo "Running...$jobInQuestion"
            if atLeastVersion 9.2; then
				notImpemented
            else
                copyEc2Properties
				myEnvVariables[ANT_OPTS]="$(getAntOptsBasic) $PARQUET"
                setEnvVars
                runAnt 17 19 "clean-all unit"
            fi
            ;;

		# jobNames[psfItTests]="$(getGB 'Parquet Integration Tests')"
		'psfItTests')
            echoInfo "Running...$jobInQuestion"
            if atLeastVersion 9.2; then
				notImpemented
            else
                copyEc2Properties
                ANT_OPTS="$ANT_OPTS $PARQUET"
                ANT_OPTS="$ANT_OPTS -Xmx1024m -XX:MaxPermSize=256m"
                ANT_OPTS="$ANT_OPTS -XX:SurvivorRatio=6"
                ANT_OPTS="$ANT_OPTS -XX:+UseConcMarkSweepGC"
                ANT_OPTS="$ANT_OPTS -XX:CMSInitiatingOccupancyFraction=80"
                ANT_OPTS="$ANT_OPTS -DshowOutput=false"
                ANT_OPTS="$ANT_OPTS -Dhalt.on.failure=false"
                myEnvVariables[ANT_OPTS]="$ANT_OPTS"
                setEnvVars
                runAnt 17 19 "clean-all download-ec2-static-property it"
            fi
            ;;

		# jobNames[psfItTestsLong]="$(getGB 'Parquet Long Running Integration Tests')"
		'psfItTestsLong')
            echoInfo "Running...$jobInQuestion"
            if atLeastVersion 6.2; then
				notImpemented
            else
                copyEc2Properties
                ANT_OPTS="$ANT_OPTS $PARQUET"
                ANT_OPTS="$ANT_OPTS -Xmx1024m -XX:MaxPermSize=256m"
                ANT_OPTS="$ANT_OPTS -XX:SurvivorRatio=6"
                ANT_OPTS="$ANT_OPTS -XX:+UseConcMarkSweepGC"
                ANT_OPTS="$ANT_OPTS -XX:CMSInitiatingOccupancyFraction=80"
                ANT_OPTS="$ANT_OPTS -DshowOutput=false"
                ANT_OPTS="$ANT_OPTS -Dhalt.on.failure=false"
                myEnvVariables[ANT_OPTS]="$ANT_OPTS"
                setEnvVars
                runAnt 17 19 "clean-all download-ec2-static-property it-long"
            fi
            ;;

		# jobNames[psfEmbeddedCluster]="$(getGB 'Parquet Embedded Cluster')"
		'psfEmbeddedCluster')
            echoInfo "Running...$jobInQuestion"
            if atLeastVersion 6.2; then
				notImpemented
            else
                copyEc2Properties
                ANT_OPTS="$ANT_OPTS $PARQUET"
                ANT_OPTS="$ANT_OPTS -Dtest.groups=cluster,dist_sanity"
                ANT_OPTS="$ANT_OPTS -Dtest.cluster=in_vm"
                ANT_OPTS="$ANT_OPTS -Dhalt.on.failure=false"
                ANT_OPTS="$ANT_OPTS -Xmx768m"
                ANT_OPTS="$ANT_OPTS -DinstanceType=m3.large"
                myEnvVariables[ANT_OPTS]="$ANT_OPTS"
                setEnvVars
                runAnt 17 19 "clean-all download-ec2-static-property it"
            fi
            ;;

        *)
            die "Job with name '$jobInQuestion' not found/supported."
            ;;
    esac

    # If we got this far without an exiting with an error, check for unit-test files.
    # If there are none, add a dummy.
    exec addDummyUnitTestXmlIfNeeded
}

addDummyUnitTestXmlIfNeeded() {
    local jsSpecsTestFiles="$(find . -name ui-specs-results -type d | xargs -I{} find {} -name "*-results.xml" -type f)"
    local unitTestFiles="$(find . -name unit-reports -type d | xargs -I{} find {} -name "TEST-*.xml" -type f)"
    local itTestFiles="$(find . -name it-reports -type d | xargs -I{} find {} -name "TEST-*.xml" -type f)"
    local itTestFilesGradle="$(find . -name test-results -type d | xargs -I{} find {} -name "TEST-*.xml" -type f)"
    cd "$myDir"
    mkdir -pv modules/dap-common/build/reports/it-reports
    if [ -z "$jsSpecsTestFiles$unitTestFiles$itTestFiles$itTestFilesGradle" ]; then
        echoInfo "Could not find any Junit test files. Adding a dummy..."
        echo '<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
   <testsuite name="JUnitXmlReporter" errors="0" tests="1" failures="0" time="0" timestamp="2015-01-01T00:00:01">
      <testcase classname="DummyTestToFoolBambooJunitParser" name="dummyTest" time="0.000" />
   </testsuite>
</testsuites>' > modules/dap-common/build/reports/it-reports/junit-template.xml
    else
        echoDebug "Found following junit test files: "
        echoDebug "Listing: jsSpecsTestFiles"
        echoDebug "$jsSpecsTestFiles"
        echoDebug "Listing: unitTestFiles"
        echoDebug "$unitTestFiles"
        echoDebug "Listing: itTestFiles"
        echoDebug "$itTestFiles"
        echoDebug "Listing: itTestFilesGradle"
        echoDebug "$itTestFilesGradle"
    fi

}
setDryRun() { DRYRUN=1; }
setVerbose() { VERBOSE=1; }


function finish {
    echoInfo "In cleanup function."
    # cleanup gradle temp directory if created.
    [[ "${gradleTmpDir:-}" == $GRADLE_TMP_BASE/* ]] && rm -rf "$gradleTmpDir"
}
trap finish EXIT

###############################################
# Program
###############################################
myDir="$(pwd)"
# Options parsing
while getopts “:hvdlLj:” OPTION
do
     case $OPTION in
    h)
        usage
        exit
        ;;
    d)
        setDryRun
        ;;
    j)
        JOB_ARG=$OPTARG
        ;;
    l)
        listJobs
        exit 0
        ;;
    L)
        listJobsAndDryRun
        exit 0
        ;;
    v)
        setVerbose
        ;;
    ?)
        die "Unrecognised option."
        ;;
    esac
done


# atLeastVersion 6 && echo "6 yes" || echo "6 no"
# atLeastVersion 6.2 && echo "6.2 yes" || echo "6.2 no"
# atLeastVersion 6.11 && echo "6.11 yes" || echo "6.11 no"
# atLeastVersion 6.2.0 && echo "6.2.0 yes" || echo "6.2.0 no"
# atLeastVersion 6.1.9 && echo "6.1.9 yes" || echo "6.1.9 no"
runJob "${JOB_ARG:-}"
[ $? -eq 0 ] && echo "Done!"
