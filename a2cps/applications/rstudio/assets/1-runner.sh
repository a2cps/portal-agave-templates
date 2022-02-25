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
echo "TACC: loading singularity"
module load tacc-singularity

# TAP integration
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

# Create temp directories for containerized application
rservdir=$(python -c 'import tempfile; print(tempfile.mkdtemp())')
mkdir -p -m 700 ${rservdir}/run ${rservdir}/tmp ${rservdir}/var/lib/rstudio-server
cat >${rservdir}/database.conf <<END
provider=sqlite
directory=/var/lib/rstudio-server
END

# Create session files
#
# Set OMP_NUM_THREADS to prevent OpenBLAS (and any other OpenMP-enhanced
# libraries used by R) from spawning more threads than the number of processors
# allocated to the job.
#
# Set R_LIBS_USER to a path specific to rocker/rstudio to avoid conflicts with
# personal libraries from any R installation in the host environment

# File session.sh sets external env vars for the R server process
cat >${rservdir}/rsession.sh <<END
#!/bin/sh
export OMP_NUM_THREADS=${SLURM_JOB_CPUS_PER_NODE}
export R_LIBS_USER=${HOME}/R/rocker-rstudio/4.0
exec rsession "\${@}"
END
chmod +x ${rservdir}/rsession.sh

# File rsession.conf sets within-R config options
cat >${rservdir}/rsession.conf <<END
# R Session Configuration File
#
session-default-working-dir=$JOB_DIR
session-default-new-project-dir=$JOB_DIR
session-timeout-minutes=0
session-timeout-kill-hours=24
session-save-action-default=yes
END

# File rserver.conf configures the server
# Important for setting up SSL!
cat >${rservdir}/rserver.conf <<END
# R Server Configuration File
#
rsession-which-r=/usr/local/bin/R
ssl-enabled=1
ssl-certificate=$(cat ${TAP_CERTFILE})
ssl-certificate-key=$(cat ${TAP_CERTFILE}) 
END

# Set up bind mounts via SINGULARITY env var - simplifies the command CLI substantially
export SINGULARITY_BIND="${rservdir}/run:/run,${rservdir}/tmp:/tmp,${rservdir}/database.conf:/etc/rstudio/database.conf,${rservdir}/rsession.conf:/etc/rstudio/rsession.conf,${rservdir}/rserver.conf:/etc/rstudio/rserver.conf,${rservdir}/rsession.sh:/etc/rstudio/rsession.sh,${rservdir}/var/lib/rstudio-server:/var/lib/rstudio-server,/corral-secure:/corral-secure"

# Set other Singularity environment vars
# export SINGULARITYENV_RSTUDIO_SESSION_TIMEOUT=0
# These are interpreted inside the container as USER and PASSWORD
export SINGULARITYENV_USER=$(id -un)
export SINGULARITYENV_PASSWORD=${TAP_TOKEN}

# Source: index.docker.io/rocker/rstudio:4.1.2
# Latest 4.x R installed on Frontera is 4.0.3
# Source: index.docker.io/rocker/rstudio:4.0.3
# TODO - test if other Rocker packages can be used.
# https://www.rocker-project.org/images/
# tidyverse, verse, geospatial
RSTUDIO_IMAGE="docker://index.docker.io/rocker/rstudio:4.0.3"

echo "TACC: using rstudio image $RSTUDIO_IMAGE"
RSTUDIO_BIN="singularity exec $RSTUDIO_IMAGE rserver"

# our node name
NODE_HOSTNAME=$(hostname -s)
echo "TACC: running on node $NODE_HOSTNAME"
# node IP address
NODE_IPV4=$(hostname -i)

# make .rstudio dir for logs
RSTUDIO_SERVERDIR=$HOME/.rstudio-app
mkdir -p $RSTUDIO_SERVERDIR
rm -f $RSTUDIO_SERVERDIR/.rstudio_address $RSTUDIO_SERVERDIR/.rstudio_port $RSTUDIO_SERVERDIR/.rstudio_status $RSTUDIO_SERVERDIR/.rstudio_job_id $RSTUDIO_SERVERDIR/.rstudio_job_start $RSTUDIO_SERVERDIR/.rstudio_job_duration

# Pull Rstudio image into cache
singularity pull -F ${RSTUDIO_IMAGE} || exit 1

# launch Rstudio in a container
RSTUDIO_LOGFILE=$RSTUDIO_SERVERDIR/$NODE_HOSTNAME.log
LOCAL_PORT=8787
RSTUDIO_ARGS="--www-port $LOCAL_PORT --server-user $USER --auth-none=0 --auth-pam-helper-path=pam-helper --auth-stay-signed-in-days=30 --auth-timeout-minutes=0 --rsession-path=/etc/rstudio/rsession.sh"
echo "TACC: using rstudio command: $RSTUDIO_BIN $RSTUDIO_ARGS"
# Change into work directory and launch RStudio
cd $JOB_DIR
nohup $RSTUDIO_BIN $RSTUDIO_ARGS &>$RSTUDIO_LOGFILE && rm $RSTUDIO_SERVERDIR/.rstudio_lock &
RSTUDIO_PID=$!
echo "$NODE_HOSTNAME $RSTUDIO_PID" >$RSTUDIO_SERVERDIR/.rstudio_lock
sleep 30

# Get a port from TAP
LOGIN_PORT=$(tap_get_port)
echo "TACC: got login node jupyter port ${LOGIN_PORT}"

# create reverse tunnel port to login nodes.
for i in $(seq 4); do
    ssh -q -f -g -N -R $LOGIN_PORT:$NODE_HOSTNAME:$LOCAL_PORT login$i
done
echo "TACC: created reverse ports on Frontera logins"

# Notify via job.out
echo "Your RStudio Server is now running!"
echo "Please point your favorite web browser to https://$PUBLIC_HOSTNAME:$LOGIN_PORT/"

# Notify user via email notification
# ref: https://bitbucket.org/taccaci/portal-agave-templates/src/master/frontera/applications/jupyter-hpc/wrapper.sh
echo -e "Your RStudio Server is now running at https://$PUBLIC_HOSTNAME:$LOGIN_PORT\nLog in with your TACC username and password ${TAP_TOKEN} when prompted.\n\n\nThis message was auto-generated. If you'd like to contact us, don't reply to this email. Instead, please submit a ticket at https://$PORTAL_HOSTNAME/tickets/new." | mailx -v -s "Access your RStudio Server" -S smtp=smtp://relay.tacc.utexas.edu -S from="$PORTAL_NAME Apps <no-reply@$PUBLIC_HOSTNAME>" ${email}

# spin on .jupyter_lockfile to keep job alive
while [ -f $RSTUDIO_SERVERDIR/.rstudio_lock ]; do
    sleep 10
done

# job is done!
echo "TACC: release port returned $(tap_release_port ${LOGIN_PORT} 2>/dev/null)"

# wait a brief moment so RStudio Server can clean up after itself
sleep 1

echo "TACC: job $SLURM_JOB_ID execution finished at: $(date)"
