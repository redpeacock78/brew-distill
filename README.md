# brew-distill

The executable local and CI-side slice of the Community Bottle distribution layer described in the v0.4 design is here:

- Formula identity from `brew info --json=v2`
- deterministic dependency fingerprints
- topological dependency plans
- local Bottle SHA256 verification
- one-at-a-time Homebrew installation
- `install`, `upgrade`, `fetch`, `verify`, `info`, `search`, `doctor`, `request`, `protect`, `unprotect`, and `gc` commands
- native Bottle build flow with the Csound DSP smoke test
- strict release-build artifact-domain gate
- legacy host, installer, OpenCore, guest, overlay, batch, diagnostics, and promotion gates

Run the external command directly while developing:

```sh
./brew-distill doctor
./brew-distill info csound
./brew-distill install --dry-run csound
scripts/native-build csound out
scripts/package-release out release "$GITHUB_RUN_ID" "$GITHUB_RUN_ATTEMPT"
```

On a fresh macOS runner, verify a released Bottle without reusing the build installation:

```sh
scripts/native-verify csound \
  release/csound--6.18.1.ventura.bottle.tar.gz \
  BOTTLE_SHA256 out/native-verify
```

When producing a release candidate, source fallback must be disabled explicitly:

```sh
DISTILL_RELEASE_BUILD=1 \
HOMEBREW_ARTIFACT_DOMAIN=https://artifacts.example.invalid \
HOMEBREW_ARTIFACT_DOMAIN_NO_FALLBACK=1 \
scripts/native-build csound out
```

Homebrew metadata can be supplied from a JSON file for offline planning and tests with `--formula-data`. A local registry is an object containing a `bottles` array. Each entry uses the manifest shape from the design:

```json
{
  "schema": 4,
  "bottles": [
    {
      "formula": {
        "name": "csound",
        "version": "6.18.1",
        "revision": 0,
        "formula_sha256": "..."
      },
      "platform": {
        "os": "macos",
        "version": "13",
        "arch": "x86_64",
        "bottle_tag": "ventura"
      },
      "dependencies": { "fingerprint": "..." },
      "artifact": {
        "path": "csound.bottle.tar.gz",
        "sha256": "..."
      }
    }
  ]
}
```

Install a verified local Bottle through Homebrew:

```sh
./homebrew-distill install csound \
  --registry registry.json \
  --bottle-dir bottles
```

`package-release` creates an immutable local bundle containing Bottle files, Homebrew Bottle JSON, individual manifests, an aggregate registry manifest, checksums, and a metadata archive. It does not upload or publish the bundle.

After reviewing that bundle, publication is a separate explicit operation:

```sh
DISTILL_PUBLISH=1 scripts/publish-release release/distill-build-123-1 \
  distill-build-123-1 owner/repo
```

The publisher rechecks `checksums.txt`, refuses an existing tag, and uploads the Bottle and metadata assets through `gh`.

The `Publish Community Bottles` workflow is the CI/CD path for native publication. It first creates a Draft Release, then each build runner uploads its Bottle, Bottle JSON, and manifest directly to that release. Fresh verification runners read the matching manifest and Bottle from the Draft Release and add only a compact verification record. After all four platforms pass, the final job downloads control-plane JSON only, creates the aggregate manifest and checksums from GitHub's asset digests, uploads the metadata, and changes the Draft Release to a formal Release. Installer files, qcow2 images, and COW overlays never enter the Release or an Actions Artifact; a failed run leaves its draft for inspection.

Source artifacts can be prefetched into the content-addressed layout with trusted metadata:

```sh
scripts/prefetch sources.json cas cas/urls.json
```

The metadata is either an array or `{ "artifacts": [...] }`, with each item containing an HTTP(S) URL and its expected SHA256. A failed checksum stops the run and the mapping is only replaced after all records succeed.

Serve the resulting CAS read-only, including Homebrew artifact-domain URL lookup and HTTP ranges:

```sh
./cas-gateway --root cas --mapping cas/urls.json
```

The gateway returns `404` for misses and never fetches upstream or accepts writes.

The legacy host probe and ephemeral COW image step are available independently:

```sh
scripts/hvf/probe out/hvf
scripts/hvf/create-base out/hvf/base.qcow2 64G out/hvf
scripts/hvf/create-overlay base.qcow2 overlay-csound.qcow2
```

The probe writes `host-info.json` and exits with `LEGACY_HVF_UNAVAILABLE` until both the host HVF bit and QEMU's `hvf` accelerator are present.

For the Phase 1 Linux guest check, provide externally built kernel and initrd assets:

```sh
DISTILL_LINUX_KERNEL=kernel DISTILL_LINUX_INITRD=initrd \
  scripts/hvf/tiny-linux linux-disk.qcow2 out/hvf
```

The legacy preparation steps are deliberately input-driven:

```sh
scripts/hvf/reclaim-disk out/hvf report
scripts/hvf/fetch-installer 13.7.8 out/hvf
DISTILL_OPENCORE_DIR=/path/to/oc-config \
  scripts/hvf/prepare-opencore 13 out/hvf/opencore
DISTILL_BASE_IMAGE=out/hvf/base.qcow2 \
  scripts/hvf/freeze-base
```

`prepare-opencore` accepts configuration files only and rejects VM images. `fetch-installer`, `bootstrap-guest`, and `bootstrap-homebrew` refuse to run outside macOS; `startosinstall` is never invoked from Linux. `boot-guest` requires macOS/HVF and accepts an optional JSON QEMU argument configuration.

`fetch-installer` searches the standard system and user Applications directories, checks the macOS software-update cache locations for a cached `InstallAssistant` package, waits for the app to appear after `softwareupdate` reports completion, and can resolve the exact OS version from Apple's software-update catalog when a hosted runner leaves no app or cache package behind. The catalog fallback downloads the signed `InstallAssistant.pkg` with parallel `aria2c` connections when available and falls back to curl, records its URL and SHA256, extracts it with `CM_BUILD=CM_BUILD`, and validates the resulting installer against the catalog's target version and package bundle version. `installer.json` keeps the requested OS version in `version` and the app's `CFBundleShortVersionString` in `bundle_version`; Apple may use different values for these fields. Package extraction output is retained in `installer-package.log`. `installer-capabilities` is run immediately afterward by `legacy-poc`, so `startosinstall --usage` and its detected options are available before the bootstrap hook starts. Big Sur and later installers use `SharedSupport.dmg` as the boot image when `BaseSystem.dmg` is absent.

Set `DISTILL_OPENCORE_STRICT=1` for a real Legacy run. Strict preparation validates `config.plist`, `EFI/BOOT/BOOTx64.efi`, and `EFI/OC/OpenCore.efi` before creating the base image. The OpenCore directory is configuration and boot media input; VM images remain rejected.

`scripts/hvf/legacy-poc MACOS_VERSION BATCH.json` runs the host-side order through probe, disk audit, installer acquisition, OpenCore preparation, base image creation, freeze, prefetch, and batch build. It requires `DISTILL_LEGACY_BOOTSTRAP`, an executable hook receiving `INSTALLER BASE.qcow2 OPENCORE-DIR HVF-OUTPUT-DIR`; the hook performs the guest-only `startosinstall` and Homebrew bootstrap, then returns the installed base image.

The hook must create the guest account before the normal build callback uses SSH. After the account exists, copy `scripts/hvf/provision-ssh` into the guest and run it as root with `DISTILL_GUEST=1` and `DISTILL_GUEST_SSH_PUBLIC_KEY_FILE=...`; it installs the supplied key into `authorized_keys`, enables Remote Login, and writes `ssh-ready.json`. The host-side `guest-ssh` wrapper accepts `DISTILL_GUEST_SSH_IDENTITY`, `DISTILL_GUEST_KNOWN_HOSTS`, `DISTILL_GUEST_SSH_TARGET`, and `DISTILL_GUEST_SSH_PORT`, and requires the identity when `DISTILL_REQUIRE_GUEST_SSH_IDENTITY=1`.

`build-batch` creates one overlay per formula and calls the executable in `DISTILL_GUEST_BUILD` with `FORMULA OVERLAY ARTIFACT-DIR`. The callback owns guest boot/SSH and must export a Bottle. Batch dependencies must appear before their dependents in `formulas`; dependencies omitted from the batch are assumed to be present in the frozen base. A failed formula is recorded while independent formulas continue; dependent formulas become `SKIPPED_DEPENDENCY`.

```sh
DISTILL_BASE_IMAGE=out/hvf/base.qcow2 \
DISTILL_GUEST_BUILD=./scripts/hvf/build-formula \
scripts/hvf/build-batch batch.json
scripts/hvf/verify-bottle csound out/csound.bottle.tar.gz \
  out/hvf/base.qcow2 out
```

The default guest callback runs the Homebrew build/test/linkage flow and the Csound smoke test over SSH, then copies Bottle files back to the artifact directory. `verify-bottle` repeats installation on a fresh overlay. The checked-in Legacy Workflow uploads successful Bottles directly to a per-run Draft Release, downloads them back from that Draft, verifies each one on a fresh overlay, and appends one compact verification record; the Actions Artifact contains diagnostics only.

Diagnostics and trust promotion are explicit:

```sh
scripts/hvf/export-diagnostics out diagnostics.tar.gz
scripts/hvf/promote evidence.json out/promotion.json
```

No VM image is published. OpenCore configuration, logs, Bottle files, and metadata may be exported; the base image and overlays remain job-local.

Static formula batches are checked against p95 timing data before scheduling:

```sh
DISTILL_BATCH_BOOTSTRAP_SECONDS=2400 \
  scripts/batch-plan batch.json timings.json out/batch-plan.json
```

The planner reserves 60 minutes and exits with `BATCH_OVER_BUDGET` when the configured workload exceeds the 300-minute default. Automatic bin packing remains a later step.

Run the legacy disk gate before creating a guest:

```sh
scripts/hvf/disk-audit out/hvf 35 before
```

It records free space and large known tooling paths, then exits with `LEGACY_DISK_INSUFFICIENT` below the configured threshold.

Installer option detection stays inside the macOS environment:

```sh
scripts/hvf/installer-capabilities \
  "/Applications/Install macOS Ventura.app" out/hvf
```

It records `startosinstall --usage` and the detected flags without assuming a fixed installer version.

The Legacy workflow expects repository variables `DISTILL_ARTIFACT_DOMAIN`, `DISTILL_LEGACY_BOOTSTRAP`, the pinned Homebrew installer URL/SHA (`DISTILL_HOMEBREW_INSTALLER_URL` and `DISTILL_HOMEBREW_INSTALLER_SHA256`), and either a runner-visible `DISTILL_OPENCORE_DIR` or a pinned `DISTILL_OPENCORE_ARCHIVE_URL` plus `DISTILL_OPENCORE_ARCHIVE_SHA256`. When `DISTILL_QEMU_ARGS_JSON` uses `{{QEMU_CODE}}` and `{{QEMU_VARS}}`, the matching pinned firmware URL/SHA variables must also be set. The archive must contain a complete EFI tree and `config.plist`; `fetch-opencore` verifies its SHA256 and rejects unsafe entries before extraction. The encrypted secrets `DISTILL_GUEST_SSH_PRIVATE_KEY` and `DISTILL_QEMU_ARGS_JSON` provide the host identity and macOS-specific QEMU arguments (including firmware, network forwarding, and any required machine credentials). The workflow derives the public key into the runner temporary directory for the bootstrap hook and optionally accepts `DISTILL_GUEST_SSH_KNOWN_HOSTS`. It fails before QEMU work when these inputs or strict OpenCore files are absent. Actual GitHub upload/publication and the legacy guest run also require the runner's QEMU, macOS Installer, and guest account/bootstrap implementation. HTTPS registry Bottle URLs are downloaded to a temporary path and SHA256 checked before Homebrew receives them; Homebrew's download cache is never impersonated.

The `CI` workflow runs the syntax checks, ShellCheck, self-contained test suite, and external `brew distill` command smoke test on every push and pull request. The checked-in workflows provide the requested native `macOS × arch` matrix, a separate fresh-runner Bottle verification matrix, and the `macos-15-intel` research entry point. Native jobs require the `DISTILL_ARTIFACT_DOMAIN` repository variable. The legacy job requires `DISTILL_LEGACY_BOOTSTRAP`, either `DISTILL_OPENCORE_DIR` or the pinned OpenCore archive variables, `DISTILL_GUEST_SSH_PRIVATE_KEY`, and `DISTILL_QEMU_ARGS_JSON`; its preflight validates these before QEMU starts, and the bootstrap hook is the only component allowed to perform guest-side installation.

Run the self-contained checks with:

```sh
ruby test/test_brew_distill.rb
for test in test/test_*.sh; do "$test"; done
```
