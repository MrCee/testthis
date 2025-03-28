#!/bin/bash

###########################################
# 🚨 SAFETY WARNING: Destructive Operation
###########################################
echo "⚠️ WARNING: This script will DELETE your persistent database and bind-mounted directories. Are you sure you want to continue?"
read -rp "Type 'y' to continue: " INITIAL_CONFIRM
if [[ ! "$INITIAL_CONFIRM" =~ ^[Yy]$ ]]; then
  echo "Aborting as per user request."
  exit 1
fi

###########################################
# 📝 Logging Setup
###########################################
[[ -f build.log ]] && mv build.log build.previous.log
exec > >(tee build.log) 2>&1
set -euo pipefail

###########################################
# 🗓️ Reproducible Build Date
###########################################
export BUILD_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "📆 Build date set to: $BUILD_DATE"

###########################################
# 🧭 Detect Docker Tools
###########################################
DOCKER_BUILDX="docker buildx"
[[ $(command -v docker-buildx) ]] && DOCKER_BUILDX="docker-buildx"

DOCKER_COMPOSE="docker compose"
[[ $(command -v docker-compose) ]] && DOCKER_COMPOSE="docker-compose"

###########################################
# ♻️ Optional Cleanup Prompt
###########################################
echo "⚠️ This will delete containers, volumes, images, and perform a --no-cache rebuild."
read -rp "Proceed with cleanup and rebuild using --no-cache? [y/N]: " CONFIRM
if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "🧹 Performing cleanup..."
  $DOCKER_COMPOSE down -v || true
  docker image prune -a -f || true
  $DOCKER_BUILDX prune --force --all || true
  sudo rm -rf invoiceplane_* mariadb || true
  NO_CACHE_FLAG="--no-cache"
else
  echo "⏩ Skipping cleanup."
  NO_CACHE_FLAG=""
fi

###########################################
# 🔧 Ensure Healthy Buildx Builder
###########################################
echo "🔍 Checking buildx builder: multiarch-builder"

if ! $DOCKER_BUILDX inspect multiarch-builder >/dev/null 2>&1; then
  
  echo "⚙️ Creating buildx builder: multiarch-builder"
  $DOCKER_BUILDX create --use --name multiarch-builder --driver docker-container
else
  echo "✅ Buildx builder config exists."

  if ! docker ps -a --format '{{.Names}}' | grep -q 'buildx_buildkit_multiarch-builder0'; then
    echo "🛠️ Builder container missing, recreating..."
    $DOCKER_BUILDX rm multiarch-builder || true
    $DOCKER_BUILDX create --use --name multiarch-builder --driver docker-container
  else
    echo "✅ Builder container is healthy."
    $DOCKER_BUILDX use multiarch-builder
  fi
fi

$DOCKER_BUILDX inspect --bootstrap

# 🧪 Dummy build to force-start builder container if needed
echo -e "FROM busybox\nRUN echo OK" > /tmp/Dockerfile.bootstrap
$DOCKER_BUILDX build --platform linux/amd64 -f /tmp/Dockerfile.bootstrap -t dummy-builder /tmp || true
rm -f /tmp/Dockerfile.bootstrap

###########################################
# 🔄 Load .env
###########################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
if [[ -f "$ENV_FILE" ]]; then
  echo "🔄 Loading .env from $ENV_FILE"
  set -o allexport
  source "$ENV_FILE"
  set +o allexport
else
  echo "❌ ERROR: .env not found at $ENV_FILE"
  exit 1
fi

###########################################
# 📂 Detect Project Root & Build Context
###########################################
PROJECT_ROOT="$SCRIPT_DIR"
while [[ "$PROJECT_ROOT" != "/" && ! -f "$PROJECT_ROOT/Dockerfile" ]]; do
  PROJECT_ROOT="$(dirname "$PROJECT_ROOT")"
done
[[ -f "$PROJECT_ROOT/Dockerfile" ]] || { echo "❌ ERROR: Dockerfile not found in project root!"; exit 1; }

cd "$PROJECT_ROOT"
BUILD_CONTEXT="$PROJECT_ROOT"
echo "📂 Project root: $PROJECT_ROOT"

###########################################
# ✅ Check Required Environment Variables
###########################################
REQUIRED_VARS=("PHP_VERSION" "IP_VERSION" "IP_IMAGE" "IP_LANGUAGE" "IP_SOURCE" "PUID" "PGID")
for VAR in "${REQUIRED_VARS[@]}"; do
  [[ -n "${!VAR:-}" ]] || { echo "❌ ERROR: Missing $VAR in .env"; exit 1; }
done

###########################################
# 🧠 Detect Architecture
###########################################
ARCH=$(uname -m)
case "$ARCH" in
  x86_64) PLATFORM="linux/amd64" ;;
  arm64|aarch64) PLATFORM="linux/arm64" ;;
  *) echo "❌ Unsupported architecture: $ARCH"; exit 1 ;;
esac
echo "✅ Detected architecture: $ARCH → $PLATFORM"

###########################################
# ⚙️ Setup QEMU for ARM Builds (Optional)
###########################################
if [[ "$PLATFORM" == "linux/arm64" ]]; then
  echo "🔍 Attempting QEMU setup for cross-build..."
  docker run --rm --privileged multiarch/qemu-user-static --reset -p yes \
    && echo "✅ QEMU multiarch setup complete." \
    || echo "⚠️ QEMU setup failed. Continuing anyway..."
fi

###########################################
# 🏷️ Choose Build Mode: Push or Load
###########################################
read -rp "Do you want to push the image? (y/N): " PUSH_RESPONSE
PUSH_RESPONSE=$(echo "$PUSH_RESPONSE" | tr '[:upper:]' '[:lower:]')
BUILD_MODE="load"
[[ "$PUSH_RESPONSE" == "y" ]] && BUILD_MODE="push" && echo "📤 Images will be pushed to Docker Hub." || echo "📦 Image will be loaded locally."

###########################################
# 🧩 Shared Build Arguments
###########################################
COMMON_BUILD_ARGS=(
  --build-arg BUILD_DATE="$BUILD_DATE"
  --build-arg PHP_VERSION
  --build-arg IP_LANGUAGE
  --build-arg IP_VERSION
  --build-arg IP_SOURCE
  --build-arg IP_IMAGE
  --build-arg PUID
  --build-arg PGID
)

###########################################
# 🔨 Build Image (Multiarch or Native)
###########################################
if [[ "$BUILD_MODE" == "push" ]]; then
  echo "🚀 Building & pushing multiarch image: ${IP_IMAGE}:${IP_VERSION}"
  $DOCKER_BUILDX build $NO_CACHE_FLAG --progress=plain \
    --platform linux/amd64,linux/arm64 \
    --push \
    "${COMMON_BUILD_ARGS[@]}" \
    --cache-to=type=inline \
    --cache-from=type="registry,ref=${IP_IMAGE}:${IP_VERSION}" \
    -t "${IP_IMAGE}:${IP_VERSION}" \
    -t "${IP_IMAGE}:latest" \
    "$BUILD_CONTEXT"

  echo "🔍 Verifying image manifests..."
  $DOCKER_BUILDX imagetools inspect "${IP_IMAGE}:${IP_VERSION}"
  $DOCKER_BUILDX imagetools inspect "${IP_IMAGE}:latest"
else
  echo "🚀 Building for native architecture only: $PLATFORM"
  $DOCKER_BUILDX build $NO_CACHE_FLAG --progress=plain \
    --platform "$PLATFORM" \
    --load \
    "${COMMON_BUILD_ARGS[@]}" \
    -t "${IP_IMAGE}:${IP_VERSION}" \
    "$BUILD_CONTEXT"
fi

###########################################
# ✅ Completion Info
###########################################
echo "✅ Build complete!"
if [[ "$BUILD_MODE" == "push" ]]; then
  echo "📦 Published:"
  echo "   - ${IP_IMAGE}:${IP_VERSION}"
  echo "   - ${IP_IMAGE}:latest"
else
  echo "📦 Local image: ${IP_IMAGE}:${IP_VERSION}"
  echo "🚀 To push manually:"
  echo "docker push ${IP_IMAGE}:${IP_VERSION}"
  echo "docker tag ${IP_IMAGE}:${IP_VERSION} ${IP_IMAGE}:latest"
  echo "docker push ${IP_IMAGE}:latest"
fi

echo "🎉 All done!"


