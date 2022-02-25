TAP_FUNCTIONS="/share/doc/slurm/tap_functions"
if [ -f ${TAP_FUNCTIONS} ]; then
    . ${TAP_FUNCTIONS}
else
    echo "TACC:"
    echo "TACC: ERROR - could not find TAP functions file: ${TAP_FUNCTIONS}"
    echo "TACC: ERROR - Please submit a consulting ticket at the TACC user portal"
    echo "TACC: ERROR - https://portal.tacc.utexas.edu/tacc-consulting/-/consult/tickets/create"
    echo "TACC:"
    echo "TACC: job $SLURM_JOB_ID execution finished at: $(date)"
    exit 1
fi

echo job $SLURM_JOB_ID execution at: $(date)

echo "TACC: unloading xalt"
module unload xalt

# passed from Tapis Jobs service
email="${email}"
workdir="${workdir}"

if [ -z "$workdir" ]; then
    JOB_DIR="/corral-secure/projects/A2CPS/shared/$USER"
else
    JOB_DIR=$workdir
fi
echo "TACC: job working directory: $JOB_DIR"

# Unpack gotty application
# https://github.com/yudai/gotty/releases/tag/v1.0.1
tar -zxf gotty_linux_amd64.tar.gz
GOTTY_BIN="${PWD}/gotty"
echo "TACC: using gotty binary $GOTTY_BIN"
GOTTY_COMMAND=$(which bash)

# public host name
PUBLIC_HOSTNAME="frontera.tacc.utexas.edu"
# portal host name
PORTAL_HOSTNAME="a2cps.org"
# portal name
PORTAL_NAME="A2CPS"

# our node name
NODE_HOSTNAME=$(hostname -s)
echo "TACC: running on node $NODE_HOSTNAME"
# node IP address
NODE_IPV4=$(hostname -i)

# make .gotty dir for logs
GOTTY_SERVERDIR=$HOME/.gotty-app
mkdir -p $GOTTY_SERVERDIR
rm -f $GOTTY_SERVERDIR/.gotty_address $GOTTY_SERVERDIR/.gotty_port $GOTTY_SERVERDIR/.gotty_status $GOTTY_SERVERDIR/.gotty_job_id $GOTTY_SERVERDIR/.gotty_job_start $GOTTY_SERVERDIR/.gotty_job_duration

# .tap directory holds the temporary certfile
mkdir -p ${HOME}/.tap # this should exist at this point, but just in case...
TAP_LOCKFILE=${HOME}/.tap/.${SLURM_JOB_ID}.lock
TAP_CERTFILE=${HOME}/.tap/.${SLURM_JOB_ID}

# bail if we cannot create a secure session
if [ ! -f ${TAP_CERTFILE} ]; then
    echo "TACC: ERROR - could not find TLS cert for secure session"
    echo "TACC: job ${SLURM_JOB_ID} execution finished at: $(date)"
    exit 1
fi

# launch gotty
GOTTY_LOCAL_PORT=9001
# generate random password for session
GOTTY_PASSWORD=$(echo -e $RANDOM | md5sum | cut -c-24)

GOTTY_LOGFILE=$GOTTY_SERVERDIR/$NODE_HOSTNAME.log
# GOTTY_ARGS="--address $NODE_IPV4 --port $GOTTY_LOCAL_PORT --permit-write --credential $USER:$GOTTY_PASSWORD --random-url $GOTTY_COMMAND"
# This version of GOTTY_ARGS creates a random URL for the sesssion, known only to the user,
# and restricts it to a single client connection
GOTTY_ARGS="--address $NODE_IPV4 --port $GOTTY_LOCAL_PORT --once --permit-write --random-url --random-url-length 64 --tls --tls-crt $(cat ${TAP_CERTFILE}) --tls-key $(cat ${TAP_CERTFILE}) $GOTTY_COMMAND"
echo "TACC: using gotty command: $GOTTY_BIN $GOTTY_ARGS"
cd $JOB_DIR
nohup $GOTTY_BIN $GOTTY_ARGS &>$GOTTY_LOGFILE && rm $GOTTY_SERVERDIR/.gotty_lock &
GOTTY_PID=$!
echo "$NODE_HOSTNAME $GOTTY_PID" >$GOTTY_SERVERDIR/.gotty_lock
sleep 5
GOTTY_RANDURL=$(grep -m 1 'URL' $GOTTY_LOGFILE | cut -d '/' -f 6)

# request a port from TAP (vis.tacc.utexas.edu)
LOGIN_GOTTY_PORT=$(tap_get_port)
echo "TACC: got login node gotty port $LOGIN_GOTTY_PORT"

# create a reverse tunnel to each of the public login nodes
for i in $(seq 4); do
    ssh -q -f -g -N -R $LOGIN_GOTTY_PORT:$NODE_HOSTNAME:$GOTTY_LOCAL_PORT login$i
done
echo "TACC: created reverse ports on Frontera logins"

# Notify user via logs
echo "Web Shell is now running!"
echo "Please point your favorite web browser to https://$PUBLIC_HOSTNAME:$LOGIN_GOTTY_PORT/$GOTTY_RANDURL/"
# echo "Enter the credentials $USER / $GOTTY_PASSWORD when prompted."

# Notify user via email notification
# ref: https://bitbucket.org/taccaci/portal-agave-templates/src/master/frontera/applications/jupyter-hpc/wrapper.sh
echo -e "Your web shell is now running at https://$PUBLIC_HOSTNAME:$LOGIN_GOTTY_PORT/$GOTTY_RANDURL/\n\n\nThis message was auto-generated. If you'd like to contact us, don't reply to this email. Instead, please submit a ticket at https://$PORTAL_HOSTNAME/tickets/new." | mailx -v -s "Access your Web Shell" -S smtp=smtp://relay.tacc.utexas.edu -S from="$PORTAL_NAME Apps <no-reply@$PUBLIC_HOSTNAME>" ${email}

# Notify user via portal webhook
# Webhook callback url for job ready notification
# ref: https://bitbucket.org/taccaci/portal-agave-templates/src/master/frontera/applications/matlab-frontera/wrapper.sh
INTERACTIVE_WEBHOOK_URL="https://$PORTAL_HOSTNAME/webhooks/interactive/"
# AGAVE_XXX tokens are supplied by the Tapis Jobs service
curl -k --data "event_type=WEB&address=https://$PUBLIC_HOSTNAME:$LOGIN_PORT/$GOTTY_RANDURL/&owner=${AGAVE_JOB_OWNER}&job_uuid=${AGAVE_JOB_ID}" $INTERACTIVE_WEBHOOK_URL &

# spin on .gotty_lockfile to keep job alive
while [ -f $GOTTY_SERVERDIR/.gotty_lock ]; do
    sleep 1
done

# job is done!
echo "TACC: release port returned $(tap_release_port ${LOGIN_PORT} 2>/dev/null)"

# wait a brief moment so gotty can clean up after itself
sleep 1

echo "TACC: job $SLURM_JOB_ID execution finished at: $(date)"
