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

echo "TACC: unloading xalt"
module unload xalt

# Set up Python environment
#
# Load latest Python3 installed on Frontera
# TODO - make this selectable via Tapis parameter
PYTHON3_MODULE="python3/3.9.2"
module load $PYTHON3_MODULE

# TODO - Why isn't jupyter-lab installed in Frontera Python3 modules?
JUPYTER_BIN=$(which jupyter-notebook)
if [ "x$JUPYTER_BIN" == "x" ]; then
    echo "TACC: could not find jupyter install"
    echo "TACC: loaded modules below"
    module list
    exit 1
fi
echo "TACC: using jupyter binary $JUPYTER_BIN"
# Detect virtualenv, anaconda, conda, etc
if $(echo $JUPYTER_BIN | grep -qve '^/opt'); then
    echo "TACC: WARNING - non-system python detected. Script may not behave as expected"
fi

# HOME Jupyter directory
NB_SERVERDIR=$HOME/.jupyter
# make .ipython dir for logs and process files
mkdir -p $NB_SERVERDIR

# HOME .tap directory holds the temporary certfile
mkdir -p ${HOME}/.tap # this should exist at this point, but just in case...
TAP_LOCKFILE=${HOME}/.tap/.${SLURM_JOB_ID}.lock
TAP_CERTFILE=${HOME}/.tap/.${SLURM_JOB_ID}

# bail if we cannot create a secure session
if [ ! -f ${TAP_CERTFILE} ]; then
    echo "TACC: ERROR - could not find TLS cert for secure session"
    echo "TACC: job ${SLURM_JOB_ID} execution finished at: $(date)"
    exit 1
fi

# bail if we cannot create a token for the session
TAP_TOKEN=$(tap_get_token)
if [ -z "${TAP_TOKEN}" ]; then
    echo "TACC: ERROR - could not generate token for notebook"
    echo "TACC: job ${SLURM_JOB_ID} execution finished at: $(date)"
    exit 1
fi
echo "TACC: using token ${TAP_TOKEN}"

# Create the jupyter config if needed
# (Tapis should stage a copy of this file into the local job directory)
TAP_JUPYTER_CONFIG="$PWD/jupyter_config.py"
if [ ! -f "${TAP_JUPYTER_CONFIG}" ]; then
    cat <<-EOF >${TAP_JUPYTER_CONFIG}
# Configuration file for TAP jupyter-notebook
import os
import ssl
os.umask(23)
c = get_config()
c.IPKernelApp.pylab = "inline"  # if you want plotting support always
c.NotebookApp.ip = "0.0.0.0"
c.NotebookApp.port = 5902
c.NotebookApp.open_browser = False
c.NotebookApp.mathjax_url = u"https://cdn.mathjax.org/mathjax/latest/MathJax.js"
c.NotebookApp.allow_origin = u"*"
c.NotebookApp.ssl_options={"ssl_version": ssl.PROTOCOL_TLSv1_2}
c.FileContentsManager.delete_to_trash = False
EOF
fi

# Clean up previous lock and other files
rm -f $NB_SERVERDIR/.jupyter_address $NB_SERVERDIR/.jupyter_port $NB_SERVERDIR/.jupyter_status $NB_SERVERDIR/.jupyter_job_id $NB_SERVERDIR/.jupyter_job_start $NB_SERVERDIR/.jupyter_job_duration

# Launch Jupyter
JUPYTER_LOGFILE=$NB_SERVERDIR/$NODE_HOSTNAME.log
JUPYTER_ARGS="--certfile=$(cat ${TAP_CERTFILE}) --config=${TAP_JUPYTER_CONFIG} --NotebookApp.token=${TAP_TOKEN}"
echo "TACC: using jupyter command: $JUPYTER_BIN $JUPYTER_ARGS"
cd $JOB_DIR
nohup $JUPYTER_BIN $JUPYTER_ARGS &>$JUPYTER_LOGFILE && rm $NB_SERVERDIR/.jupyter_lock &
JUPYTER_PID=$!
echo "$NODE_HOSTNAME $JUPYTER_PID" >$NB_SERVERDIR/.jupyter_lock
# Jupyter can take a bit to start up.. give it some room before we start trying to serve it
sleep 30
JUPYTER_TOKEN=$(grep -m 1 'token=' $JUPYTER_LOGFILE | cut -d'?' -f 2)
LOCAL_PORT=5902

# Get a port from TAP
LOGIN_PORT=$(tap_get_port)
echo "TACC: got login node jupyter port ${LOGIN_PORT}"

# create reverse tunnel port to login nodes.
for i in $(seq 4); do
    ssh -q -f -g -N -R $LOGIN_PORT:$NODE_HOSTNAME:$LOCAL_PORT login$i
done
echo "TACC: created reverse ports on Frontera logins"

# Notify via job.out
echo "Your Jupyter Notebook Server is now running!"
echo "Please point your favorite web browser to https://$PUBLIC_HOSTNAME:$LOGIN_PORT/?token=$TAP_TOKEN"

# Notify user via email notification
# ref: https://bitbucket.org/taccaci/portal-agave-templates/src/master/frontera/applications/jupyter-hpc/wrapper.sh
echo -e "Your Jupyter Notebook Server is now running at https://$PUBLIC_HOSTNAME:$LOGIN_PORT/?token=$TAP_TOKEN. \n\n\nThis message was auto-generated. If you'd like to contact us, don't reply to this email. Instead, please submit a ticket at https://$PORTAL_HOSTNAME/tickets/new." | mailx -v -s "Access your Jupyter Notebook Server" -S smtp=smtp://relay.tacc.utexas.edu -S from="$PORTAL_NAME Apps <no-reply@$PUBLIC_HOSTNAME>" ${email}

# Notify user via portal webhook
# Webhook callback url for job ready notification
# ref: https://bitbucket.org/taccaci/portal-agave-templates/src/master/frontera/applications/matlab-frontera/wrapper.sh
INTERACTIVE_WEBHOOK_URL="https://$PORTAL_HOSTNAME/webhooks/interactive/"
curl -k --data "event_type=WEB&address=https://$PUBLIC_HOSTNAME:$LOGIN_PORT/?token=$TAP_TOKEN&owner=${AGAVE_JOB_OWNER}&job_uuid=${AGAVE_JOB_ID}" $INTERACTIVE_WEBHOOK_URL &

# info for TACC Visualization Portal
echo "$PUBLIC_HOSTNAME" >$NB_SERVERDIR/.jupyter_address
echo "$LOGIN_PORT/?$JUPYTER_TOKEN" >$NB_SERVERDIR/.jupyter_port
echo "$SLURM_JOB_ID" >$NB_SERVERDIR/.jupyter_job_id
# write job start time and duration (in seconds) to file
date +%s >$NB_SERVERDIR/.jupyter_job_start
echo "$TACC_RUNTIME_SEC" >$NB_SERVERDIR/.jupyter_job_duration
sleep 5
echo "success" >$NB_SERVERDIR/.jupyter_status

# spin on .jupyter_lockfile to keep job alive
while [ -f $NB_SERVERDIR/.jupyter_lock ]; do
    sleep 10
done

# job is done!
echo "TACC: release port returned $(tap_release_port ${LOGIN_PORT} 2>/dev/null)"

# wait a brief moment so Jupyter Notebook Server can clean up after itself
sleep 1

echo "TACC: job $SLURM_JOB_ID execution finished at: $(date)"
