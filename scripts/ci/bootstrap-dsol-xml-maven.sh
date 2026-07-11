#!/usr/bin/env bash
# Install vendored dsol-xml:1.6.9 into ~/.m2 so ldbc_snb_datagen mvn build does not
# depend on simulation.tudelft.nl at runtime.
set -euo pipefail

BENCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERSION="1.6.9"
GROUP_ID="dsol"
ARTIFACT_ID="dsol-xml"
VENDOR_DIR="${BENCH_ROOT}/scripts/vendor/dsol-xml/${VERSION}"
JAR="${VENDOR_DIR}/dsol-xml-${VERSION}.jar"
POM="${VENDOR_DIR}/dsol-xml-${VERSION}.pom"
LOCAL_JAR="${HOME}/.m2/repository/${GROUP_ID}/${ARTIFACT_ID}/${VERSION}/${ARTIFACT_ID}-${VERSION}.jar"

# SHA1 from https://simulation.tudelft.nl/maven/dsol/dsol-xml/1.6.9/
EXPECTED_JAR_SHA1="def53307059b609ca59d456038615d174dac2a64"
EXPECTED_POM_SHA1="56fe718bbd4abca15f9ce5f911063966c89246f6"

if [[ -f "${LOCAL_JAR}" ]]; then
  echo "dsol-xml ${VERSION} already present in local Maven repo"
  exit 0
fi

if [[ ! -f "${JAR}" ]] || [[ ! -f "${POM}" ]]; then
  echo "missing vendored dsol-xml files under ${VENDOR_DIR}" >&2
  exit 1
fi

if ! command -v mvn >/dev/null 2>&1; then
  echo "mvn not found; cannot bootstrap dsol-xml" >&2
  exit 1
fi

actual_jar_sha1="$(sha1sum "${JAR}" | awk '{print $1}')"
actual_pom_sha1="$(sha1sum "${POM}" | awk '{print $1}')"
if [[ "${actual_jar_sha1}" != "${EXPECTED_JAR_SHA1}" ]] || [[ "${actual_pom_sha1}" != "${EXPECTED_POM_SHA1}" ]]; then
  echo "vendored dsol-xml checksum mismatch" >&2
  echo "  jar: expected ${EXPECTED_JAR_SHA1}, got ${actual_jar_sha1}" >&2
  echo "  pom: expected ${EXPECTED_POM_SHA1}, got ${actual_pom_sha1}" >&2
  exit 1
fi

echo "Installing vendored dsol-xml ${VERSION} into local Maven repo"
mvn -q install:install-file \
  -Dfile="${JAR}" \
  -DpomFile="${POM}" \
  -DgroupId="${GROUP_ID}" \
  -DartifactId="${ARTIFACT_ID}" \
  -Dversion="${VERSION}" \
  -Dpackaging=jar

echo "dsol-xml ${VERSION} bootstrap done"
