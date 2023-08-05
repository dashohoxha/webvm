#!/bin/bash

DOCKERFILE_PATH='dockerfiles/debian_systemd'
IMAGE_SIZE='600M'

# We check whether the Dockerfile_path is valid. 
if [[ ! -f $DOCKERFILE_PATH ]]; then
    echo "No file found at $DOCKERFILE_PATH"
    exit 1
fi

TAG="ext2-webvm-base-image" # Tag of docker image.
#DEPLOY_DIR=/webvm_deploy/ # Path to directory where we host the final image from.

IMAGE_NAME=$(basename $DOCKERFILE_PATH).ext2

mkdir -p $DEPLOY_DIR

# Build the i386 Dockerfile image.
docker build . --tag $TAG --file $DOCKERFILE_PATH --platform=i386
      
# Run the docker image so that we can export the container.
# Run the Docker container with the Google Public DNS nameservers: 8.8.8.8, 8.8.4.4
docker run --dns 8.8.8.8 --dns 8.8.4.4 -d $TAG
CONTAINER_ID=$(docker ps -aq)

# We extract the CMD, we first need to figure whether the Dockerfile uses CMD or an Entrypoint.
cmd=$(docker inspect --format='{{json .Config.Cmd}}' $CONTAINER_ID)
entrypoint=$(docker inspect --format='{{json .Config.Entrypoint}}' $CONTAINER_ID)
if [[ $entrypoint != "null" && $cmd != "null" ]]; then
    CMD=$(docker inspect $CONTAINER_ID | jq --compact-output '.[0].Config.Entrypoint')
    ARGS=$(docker inspect $CONTAINER_ID | jq --compact-output '.[0].Config.Cmd')
elif [[ $cmd != "null" ]]; then
    CMD=$(docker inspect $CONTAINER_ID | jq --compact-output '.[0].Config.Cmd[:1]')
    ARGS=$(docker inspect $CONTAINER_ID | jq --compact-output '.[0].Config.Cmd[1:]')
else
    CMD=$(docker inspect $CONTAINER_ID | jq --compact-output '.[0].Config.Entrypoint[:1]')
    ARGS=$(docker inspect $CONTAINER_ID | jq --compact-output '.[0].Config.Entrypoint[1:]')
fi

# We extract the ENV, CMD/Entrypoint and cwd from the Docker container with docker inspect.
ENV=$(docker inspect $CONTAINER_ID | jq --compact-output  '.[0].Config.Env')
CWD=$(docker inspect $CONTAINER_ID | jq --compact-output '.[0].Config.WorkingDir')

# We create and mount the base ext2 image to extract the Docker container's filesystem its contents into.
# Preallocate space for the ext2 image
fallocate -l $IMAGE_SIZE $IMAGE_NAME
# Format to ext2 linux kernel revision 0
mkfs.ext2 -r 0 $IMAGE_NAME
# Mount the ext2 image to modify it
mkdir -p mnt
mount -o loop -t ext2 $IMAGE_NAME mnt/

# We opt for 'docker cp --archive' over 'docker save' since our focus is solely on the end product rather than individual layers and metadata.
# However, it's important to note that despite being specified in the documentation, the '--archive' flag does not currently preserve uid/gid information when copying files from the container to the host machine.
# Another compelling reason to use 'docker cp' is that it preserves resolv.conf.
# Export and unpack container filesystem contents into mounted ext2 image.
docker cp -a ${CONTAINER_ID}:/ mnt/
umount mnt/
# Result is an ext2 image for webvm.

# Move required files for gh-pages deployment to the deployment directory $DEPLOY_DIR.
#mv assets examples xterm index.html login.html network.js scrollbar.css serviceWorker.js $DEPLOY_DIR
      
# The .txt suffix enabled HTTP compression for free
# Generate image split chunks and .meta file
split $IMAGE_NAME $DEPLOY_DIR/${IMAGE_NAME}.c -a 6 -b 128k -x --additional-suffix=.txt
bash -c "stat -c%s $IMAGE_NAME > $DEPLOY_DIR/${IMAGE_NAME}.meta"

# This step updates the default index.html file by performing the following actions:
#   1. Replaces all occurrences of IMAGE_URL with the URL to the image.
#   2. Replaces all occurrences of DEVICE_TYPE to bytes.
#   3. Replace CMD with the Dockerfile entry command.
#   4. Replace args with the Dockerfile CMD / Entrypoint args.
#   5. Replace ENV with the container's environment values.
# Adjust index.html
sed -i $DEPLOY_DIR/index.html \
    -e "s#IMAGE_URL#\"$IMAGE_NAME\"#g"  \
    -e 's#DEVICE_TYPE#"split"#g' \
    -e "s#CMD#$CMD#g" \
    -e "s#ARGS#$ARGS#g" \
    -e "s#ENV#$ENV#g" \
    -e "s#CWD#$CWD#g"

# We generate index.list files for our httpfs to function properly.
# make index.list
find $DEPLOY_DIR -type d | while read -r dir;
do
    index_list="$dir/index.list"
    rm -f "$index_list"
    ls "$dir" | tee "$index_list" > /dev/null
    chmod +rw "$index_list"
    echo "created $index_list"
done

