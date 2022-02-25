echo "TACC: unloading xalt"
module unload xalt
echo "TACC: loading singularity"
module load tacc-singularity

# passed from Tapis Jobs service
email="${email}"
workdir="${workdir}"

if [ -z "$workdir" ]; then
    echo "TACC: no workdir specified - using shared "
    export JOB_DIR="/corral-secure/projects/A2CPS/shared/$USER"
else
    export JOB_DIR=$workdir
fi
echo "TACC: job working directory: $JOB_DIR"

# portal host
PORTAL_HOSTNAME="a2cps.org"
# portal name
PORTAL_NAME="A2CPS"
# public host
PUBLIC_HOSTNAME="frontera.tacc.utexas.edu"
# app name
APP_NAME="RStudio Server"

# Get compute node name
NODE_HOSTNAME=$(hostname -s)
# Get compute node address
NODE_IPV4=$(hostname -i)
echo "TACC: running on node $NODE_HOSTNAME ($NODE_IPV4)"

# TAP integration
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

# bail if we cannot create a secure session
if [ ! -f ${TAP_CERTFILE} ]; then
    echo "TACC: ERROR - could not find TLS cert for secure session"
    echo "TACC: job ${SLURM_JOB_ID} execution finished at: $(date)"
    exit 1
fi

# bail if we cannot create a token for the session
TAP_TOKEN=$(tap_get_token)
# Truncate to make it easier to copy and paste from email
export TAP_TOKEN="${TAP_TOKEN::16}"
if [ -z "${TAP_TOKEN}" ]; then
    echo "TACC: ERROR - could not generate token for notebook"
    echo "TACC: job ${SLURM_JOB_ID} execution finished at: $(date)"
    exit 1
fi
echo "TACC: using token ${TAP_TOKEN}"

# .tap directory holds a temporary certfile
mkdir -p ${HOME}/.tap # this should exist at this point, but just in case...
TAP_LOCKFILE=${HOME}/.tap/.${SLURM_JOB_ID}.lock
TAP_CERTFILE=${HOME}/.tap/.${SLURM_JOB_ID}
# End TAP integration

# 0. Set up connection to the login nodes
PUBLIC_PORT=$(tap_get_port)
echo "TACC: got login node port $PUBLIC_PORT"
# 2. Reverse tunnel to logins
# Note that we don't need the private port because we're tunneling the proxy to the login node, not the rstudio app to the login node
for i in $(seq 4); do
    echo "TACC: $PUBLIC_PORT:$NODE_HOSTNAME:$PUBLIC_PORT <- login$i"
    ssh -q -f -g -N -R $PUBLIC_PORT:$NODE_HOSTNAME:$PUBLIC_PORT login$i
done
echo "TACC: created reverse ports on Frontera logins"

# Launch RStudio
# 1. Create temp directories for containerized application
rservdir=$(python -c 'import tempfile; print(tempfile.mkdtemp())')
mkdir -p -m 700 ${rservdir}/run ${rservdir}/tmp ${rservdir}/var/lib/rstudio-server
cat >${rservdir}/database.conf <<END
provider=sqlite
directory=/var/lib/rstudio-server
END

# 2. Create session and server config files
# session.sh sets external env vars for the R server process
#
# Set OMP_NUM_THREADS to prevent OpenBLAS (and any other OpenMP-enhanced
# libraries used by R) from spawning more threads than the number of processors
# allocated to the job.
#
# Set R_LIBS_USER to a path specific to rocker/rstudio to avoid conflicts with
# personal libraries from any R installation in the host environment
cat >${rservdir}/rsession.sh <<END
#!/bin/sh
export OMP_NUM_THREADS=${SLURM_JOB_CPUS_PER_NODE}
export R_LIBS_USER=${HOME}/R/rocker-rstudio/4.0
exec rsession "\${@}"
END
chmod +x ${rservdir}/rsession.sh

# rsession.conf sets within-R config options
cat >${rservdir}/rsession.conf <<END
# R Session Configuration File
#
session-default-working-dir=$JOB_DIR
session-default-new-project-dir=$JOB_DIR
session-timeout-minutes=0
session-save-action-default=yes
END

# 3. Configure bind mounts via SINGULARITY_BIND
# Project in run, tmp, /var/lib/rstudio-server directories
# Project in rsession.sh and rsession.conf files
# Project in corral-secure mount
export SINGULARITY_BIND="${rservdir}/run:/run,${rservdir}/tmp:/tmp,${rservdir}/database.conf:/etc/rstudio/database.conf,${rservdir}/rsession.conf:/etc/rstudio/rsession.conf,${rservdir}/rsession.sh:/etc/rstudio/rsession.sh,${rservdir}/var/lib/rstudio-server:/var/lib/rstudio-server"
# extend binds with corral-secure if the path is available on this compute node
if [ -d "/corral-secure" ]; then
    export SINGULARITY_BIND="${SINGULARITY_BIND},/corral-secure:/corral-secure"
fi
echo "TACC: container binds = ${SINGULARITY_BIND}"

# 4. Set other Singularity environment vars
# These are interpreted inside the container as USER and PASSWORD for noteboook auth
export SINGULARITYENV_USER=$(id -un)
export SINGULARITYENV_PASSWORD=${TAP_TOKEN}

# 5. Launch RStudio in a container
# Source: index.docker.io/rocker/rstudio:4.1.2
# Latest 4.x R installed on Frontera is 4.0.3
# Source: index.docker.io/rocker/rstudio:4.0.3
# TODO - test if other Rocker packages can be used.
# https://www.rocker-project.org/images/
# tidyverse, verse, geospatial
RSTUDIO_IMAGE="docker://index.docker.io/rocker/rstudio:4.0.3"
echo "TACC: using rstudio image $RSTUDIO_IMAGE"
RSTUDIO_BIN="singularity exec $RSTUDIO_IMAGE rserver"
# make .rstudio dir for logs
RSTUDIO_SERVERDIR=$HOME/.rstudio-app
mkdir -p $RSTUDIO_SERVERDIR
# Launch the Rstudio process
RSTUDIO_LOGFILE=$RSTUDIO_SERVERDIR/$NODE_HOSTNAME.log
# This is needed in two places: 1) when we launch the server and 2) to configure the proxy
PRIVATE_PORT=8787
# Pull Rstudio image into cache
singularity pull -F ${RSTUDIO_IMAGE} || exit 1
# Define launch arguments
RSTUDIO_ARGS="--www-port $PRIVATE_PORT --server-user $USER --auth-none=0 --auth-pam-helper-path=pam-helper --auth-stay-signed-in-days=30 --auth-timeout-minutes=0 --rsession-path=/etc/rstudio/rsession.sh"
echo "TACC: using rstudio command: $RSTUDIO_BIN $RSTUDIO_ARGS"
# Change into work directory and launch RStudio
cd $JOB_DIR
nohup $RSTUDIO_BIN $RSTUDIO_ARGS &>$RSTUDIO_LOGFILE && rm $TAP_LOCKFILE &
RSTUDIO_PID=$!
# Create the lockfile
echo "$NODE_HOSTNAME $RSTUDIO_PID" >$TAP_LOCKFILE
# Give server a little time to come up
sleep 30

# 6. Launch Caddy proxy
unset SINGULARITY_BIND
unset SINGULARITYENV_USER
unset SINGULARITYENV_PASSWORD
export SINGULARITYENV_PUBLIC_HOSTNAME=${PUBLIC_HOSTNAME}
export SINGULARITYENV_PUBLIC_PORT=${PUBLIC_PORT}
# Leave this blank unless you really need to set it
export SINGULARITYENV_PRIVATE_HOSTNAME=
export SINGULARITYENV_PRIVATE_PORT=${PRIVATE_PORT}
export SINGULARITYENV_LOG_LEVEL=DEBUG
export SINGULARITYENV_PEMFILE=$(cat ${TAP_CERTFILE})
export CADDY_REPO="docker://docker.io/mwvaughn/caddy-reverse-proxy"
singularity run -e ${CADDY_REPO} &>.reverseproxy.log &
echo "TACC: Proxy is now running"

# 7. Notify user via logs
echo "${APP_NAME} is now running!"
echo "Please point your web browser to https://${PUBLIC_HOSTNAME}:${PUBLIC_PORT}/"
echo "Enter credentials ${USER} / ${TAP_TOKEN} when prompted."

# 8. Notify user via email notification
# ref: https://bitbucket.org/taccaci/portal-agave-templates/src/master/frontera/applications/jupyter-hpc/wrapper.sh
echo -e "Your ${APP_NAME} is now running at https://$PUBLIC_HOSTNAME:$PUBLIC_PORT\nLog in with your TACC username and password ${TAP_TOKEN} when prompted.\n\n\nThis message was auto-generated. If you'd like to contact us, don't reply to this email. Instead, please submit a ticket at https://$PORTAL_HOSTNAME/tickets/new." | mailx -v -s "Access your ${APP_NAME}" -S smtp=smtp://relay.tacc.utexas.edu -S from="$PORTAL_NAME Apps <no-reply@$PUBLIC_HOSTNAME>" ${email}

# 9. Spin on lockfile to keep job alive
while [ -f $TAP_LOCKFILE ]; do
    sleep 10
done

# 10. Release port and exit cleanly
echo "TACC: release port returned $(tap_release_port ${PUBLIC_PORT} 2>/dev/null)"
# wait a brief moment so RStudio Server can clean up after itself
sleep 1
echo "TACC: job $SLURM_JOB_ID execution finished at: $(date)"
