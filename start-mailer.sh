#!/bin/bash

# Config based domain
MAILER_HOSTNAME=`hostname`
echo "`hostname`" > /etc/nullmailer/defaultdomain
echo "`hostname`" > /etc/nullmailer/defaulthost
echo "`hostname`" > /etc/nullmailer/me
echo "`hostname`" > /etc/mailname
export HELOHOST="`hostname`"
echo 900 >  /etc/nullmailer/pausetime

# ##########
# Log rotate
# ##########
if [ ! -d ${DATA_VOLUME_HOME}/log ]; then
	mkdir ${DATA_VOLUME_HOME}/log
fi
if [ ! -f ${DATA_VOLUME_HOME}/log/mail.log ]; then
	touch ${DATA_VOLUME_HOME}/log/mail.log
fi
cat > /etc/logrotate.d/nullmailer <<-EOF
			${DATA_VOLUME_HOME}/log/mail.log {
				weekly
				missingok
				rotate 26
				compress
				delaycompress
				notifempty
				size 10M
			}
		EOF

# ##########
# Build smtp command with $MAILER_SMTP if it sets
# ##########
if [ "${MAILER_SMTP}" = "" ]; then
	echo "MAILER_SMTP is not defined" >> ${DATA_VOLUME_HOME}/log/mail.log; >&2 awk '/./{line=$0} END{print line}' ${DATA_VOLUME_HOME}/log/mail.log 
	exit 1
fi
# Configure smtp command
IFS=':' read -ra smtp_parameters <<< "${MAILER_SMTP}"
smtp_options=""
for (( i = 0; i < ${#smtp_parameters[@]}; i++ )); do
	case "$i" in
		0)
			smtp_options="$smtp_options ${smtp_parameters[$i]}"
			;;
		1)
			smtp_options="--port=${smtp_parameters[$i]} $smtp_options"
			;;
		2)
			if [ "${smtp_parameters[$i]}" != "" ]; then
				smtp_options="--user=${smtp_parameters[$i]} $smtp_options"
			fi
			;;
		3)
			if [ "${smtp_parameters[$i]}" != "" ]; then
				smtp_options="--pass=${smtp_parameters[$i]} $smtp_options"
			fi
			;;
		*)
			;;
	esac
	case "${smtp_parameters[$i]}" in
		ssl)
			smtp_options="--ssl $smtp_options"
			;;
		starttls)
			smtp_options="--starttls $smtp_options"
			;;
		*)
			;;
	esac
done

echo "[mailer] config set !"
echo "[mailer] start waiting message"

function nullmailer_override_envelope {
	local mailfile=$1
	local sender_name=$2
	local new_sender_mail=$3
	local sender_hostname=$4
	if [ "$mailfile" = "" ] || [ ! -f $mailfile ] ; then
		errlog="$0 - Mail file $mailfile doesn't exist"
		echo $errlog
		return;
	fi
	if [ "$sender_name" = "" ]; then
		errlog="$0 - Sender name missing to envelope $mailfile"
		echo $errlog
		return;
	fi
	if [ "$new_sender_mail" = "" ]; then
		errlog="$0 - New sender mail missing to envelope $mailfile of $sender_name"
		echo $errlog
		return;
	fi
	if [ "$sender_hostname" = "" ]; then
		errlog="$0 - Original sender hostname missing to envelope $mailfile of $sender_name"
		echo $errlog
		return;
	fi
	
	# Extract mail from
	[[ "$(cat $mailfile | grep ^From:)" =~ ([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,6}) ]] && mail_from=${BASH_REMATCH[1]}
	if [ "${mail_from}" = "" ]; then
		errlog="$0 - From mail not found in $mailfile of $sender_name"
		echo $errlog
		return;
	fi
	# Extract from name
	[[ "$(cat $mailfile | grep ^From:)" =~ ^From:(.+)\<.+\> ]] && mail_from_name="$(echo -e "${BASH_REMATCH[1]}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

	# Move from to reply-to if no reply-to
	if [ $(cat $mailfile | grep ^Reply-To | wc -l) -eq 0 ]; then
		sed -ri -e 's/From:/Reply-To:/' $mailfile
		# Re-insert from
		sed -i "$(grep -n ^Reply-To $mailfile | grep -Eo '^[^:]+') a From: ${mail_from}" $mailfile
	fi
	
	# Replace from with mailadress envelope
	if [ "${mail_from_name}" != "" ]; then
		sed -ri -e "s/^From.*/From: ${mail_from_name} <${new_sender_mail}>/" $mailfile
	else
		sed -ri -e "s/^From.*/From: ${sender_hostname} <${new_sender_mail}>/" $mailfile
	fi

	# Replace envelope sender (the first line)
	sed -i "1s/.*/${new_sender_mail}/" $mailfile
	echo ""
}

last_queue_checking=$(date +"%s")
mails_queued_last_120s=0
while true
do
	sleep $(( ( RANDOM % 25 )  + 20 ))

	# ###### 
	# Rm older mails
	# ######
	find ${DATA_VOLUME_HOME} -wholename "*mail/*/*.*" -type f -iregex "${DATA_VOLUME_HOME}/.*/[0-9]*\..*" -mtime +90 -exec rm {} \;

	# Search all queue directories
	queues_dir=( $(find ${DATA_VOLUME_HOME} -wholename "${DATA_VOLUME_HOME}*mail/queue" -type d) )
	for queue_dir in "${queues_dir[@]}"; do
		# #######
		# Send queue files
		# To avoid problem with mail queuing, we send only mails whose size will not change during 0.1 seconds
		#######
		shopt -s nullglob
		mails=($queue_dir/*)
		for mailfile in "${mails[@]}"; do
			mailsize=$(du -k $mailfile | cut -f 1)
			sleep 0.1
			mailsize2=$(du -k $mailfile | cut -f 1)
			if [ $mailsize -eq $mailsize2 ]; then
				# Get user's generating the file and set as host sender
				user=$(head -n 1 $mailfile)
				sender=$(echo "$user" | sed -r 's/[@\.]+/-/g')
				[[ "$user" =~ ^.+@(.+)$ ]] && sender_hostname=${BASH_REMATCH[1]}
				mail_sender="${sender}@${MAILER_HOSTNAME}"
				# Change sender
				returnmsg=$(nullmailer_override_envelope $mailfile $sender $mail_sender $sender_hostname)
				if [ "$returnmsg" != "" ]; then
					echo "[`date +"%Y-%m-%d %H:%I:%S"`][${sender}][failed] $returnmsg" >> ${DATA_VOLUME_HOME}/log/mail.log
					mv $mailfile ${queue_dir}/../failed/$(basename $mailfile)
					continue
				fi
				# Send
				cmd="/usr/lib/nullmailer/smtp $smtp_options < $mailfile"
				eval "$( (/usr/lib/nullmailer/smtp $smtp_options < $mailfile && exitcode=$? >&2 ) 2> >(errorlog=$(cat); typeset -p errorlog) > >(stdoutlog=$(cat); typeset -p stdoutlog); exitcode=$?; typeset -p exitcode )"
				if [ $exitcode -gt 0 ]; then
					echo "[`date +"%Y-%m-%d %H:%I:%S"`][${sender}] $cmd" >> ${DATA_VOLUME_HOME}/log/mail.log
					echo "[`date +"%Y-%m-%d %H:%I:%S"`][${sender}][failed] $errorlog" >> ${DATA_VOLUME_HOME}/log/mail.log
					if [ ! -d ${queue_dir}/../failed ]; then
						mkdir ${queue_dir}/../failed
					fi
					mv $mailfile ${queue_dir}/../failed/$(basename $mailfile)
				else 
					echo "[`date +"%Y-%m-%d %H:%I:%S"`][${sender}] $cmd" >> ${DATA_VOLUME_HOME}/log/mail.log
					echo "[`date +"%Y-%m-%d %H:%I:%S"`][${sender}][done] $stdoutlog" >> ${DATA_VOLUME_HOME}/log/mail.log
					if [ ! -d ${queue_dir}/../sent ]; then
						mkdir ${queue_dir}/../sent
					fi
					mv $mailfile ${queue_dir}/../sent/$(basename $mailfile)
				fi
			fi
		done
	done
done

# Unexpected because must always run
exit 1