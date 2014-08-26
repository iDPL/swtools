#!/bin/sh

CONDOR_CHIRP=`condor_config_val LIBEXEC`/condor_chirp
MD5SUM=/usr/bin/md5sum

get_job_attr_blocking() {
    #echo "Waiting for attribute $1" 1>&2
    while /bin/true
    do
        Value=`$CONDOR_CHIRP get_job_attr $1`
        if [ $? -ne 0 ]; then
            echo "Chirp is broken!" 1>&2
            return 1
        fi
        if [ "$Value" != "UNDEFINED" ]; then
            echo "$Value" | tr -d '"'
            return 0
        fi
        sleep 2
    done
}

checksum() {
    $MD5SUM $1 | awk '{print $1}'
}

receive_server() {
    echo "I'm the server receiver"

    # Start netcat listening on an ephemeral port (0 means kernels picks port)
    #    It will wait for a connection, then write that data to output_file

    nc -d -l 0 > "$DESTINATION" &

    # pid of the nc running in the background
    NCPID=$!

    # Sleep a bit to ensure nc is running
    sleep 2

    # parse the actual port selected from netstat output
    NCPORT=`
        netstat -t -a -p 2>/dev/null |
        grep " $NCPID/nc" |
        awk -F: '{print $2}' | awk '{print $1}'`

    echo "Listening on $HOSTNAME $NCPORT"
    $CONDOR_CHIRP set_job_attr JobServerAddress \"${HOSTNAME}\ ${NCPORT}\"

    # Do other server things here...
    #sleep 60

    EXPECTED_CHECKSUM=`get_job_attr_blocking FileChecksum`
    if [ $? -ne 0 ]; then
        echo "Chirp is broken"
        return 1
    fi

    while /bin/kill -0 $NCPID >/dev/null 2>&1
    do
        ls -l $DESTINATION
        sleep 1
    done

    CHECKSUM=`checksum $DESTINATION`
    if [ "$EXPECTED_CHECKSUM" != "$CHECKSUM" ]; then
        echo "File did not arrive intact! Sender claimed checksum is $EXPECTED_CHECKSUM, but I calculated $CHECKSUM";
        return 1
    fi;

    echo "$EXPECTED_CHECKSUM==$CHECKSUM";

    $CONDOR_CHIRP set_job_attr ResultFileReceived TRUE

    return 0
}

send_client() {
    echo "I'm the client/sender"

    JobServerAddress=`get_job_attr_blocking JobServerAddress`
    if [ $? -ne 0 ]; then
        echo "Chirp is broken"
        return 1
    fi
    echo "JobServerAddress: $JobServerAddress";

    host=`echo $JobServerAddress | awk '{print $1}'`
    port=`echo $JobServerAddress | awk '{print $2}'`

    CHECKSUM=`checksum $FILE_TO_SEND`
    echo "Checksum: $CHECKSUM"

    echo "Sending to $host $port"
    echo "nc $host $port < $FILE_TO_SEND"
    ls -l $FILE_TO_SEND
    TIME_START=`date +%s`
    nc $host $port < $FILE_TO_SEND
    echo "Sent $?"
    TIME_END=`date +%s`
    $CONDOR_CHIRP set_job_attr ResultTimeStart "$TIME_START"
    $CONDOR_CHIRP set_job_attr ResultTimeEnd "$TIME_END"

    echo "Posting that transfer is done, checksum is $CHECKSUM" 
    $CONDOR_CHIRP set_job_attr FileChecksum "\"$CHECKSUM\""

    return 0
}

SENDER="$1"
FILE_TO_SEND="$2"
RECEIVER="$3"
DESTINATION="$4"

if [ "$DESTINATION" = "" ]; then
    cat <<END
Usage: $0 source_host source_file destination_host destination_file
END
    exit 1
fi

HOSTNAME=`hostname`

echo "I am $HOSTNAME, node $_CONDOR_PROCNO"
echo "$SENDER $FILE_TO_SEND -> $RECEIVER $DESTINATION"

if [ "$RECEIVER" = "$HOSTNAME" ]; then
    $CONDOR_CHIRP set_job_attr ResultsFileSent "\"$FILE_TO_SEND\""
    $CONDOR_CHIRP set_job_attr ResultsHostSend "\"$SENDER\""
    $CONDOR_CHIRP set_job_attr ResultsHostReceive "\"$RECEIVER\""
    receive_server
    RESULT=$?
    if [ $RESULT -ne 0 ]; then
        echo "Error receiving file"
    fi
elif [ "$SENDER" = "$HOSTNAME" ]; then
    send_client
    RESULT=$?
    if [ $RESULT -ne 0 ]; then
        echo "Error sending file"
    fi
else
    echo "This node was not expected. Exiting immediately"
fi;

if [[ $_CONDOR_PROCNO = "0" ]]; then
    echo "Waiting for partner"
    get_job_attr_blocking Node1Done > /dev/null
    # Give other node a bit of time to clear out after exiting.
    sleep 5
elif [[ $_CONDOR_PROCNO = "1" ]]; then
    $CONDOR_CHIRP set_job_attr Node1Done TRUE
fi

