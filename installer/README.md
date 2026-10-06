# LocalTranscriber CLI installer

The CLI installer is the canonical managed-runtime installation engine for
LocalTranscriber. It installs into the current user's account, does not require
administrator privileges, does not use Homebrew, does not modify `PATH`, and
does not alter the system Python installation.

The default managed location is:

```text
~/Library/Application Support/LocalTranscriber
```

The runtime and Whisper model are downloaded separately. Before any network
operation, the installer displays the destination, download sizes, components,
and asks for consent. The default answer is **No**. The model has its own second
consent prompt because it is downloaded directly from Hugging Face.

## Commands

Interactive full installation:

```bash
./installer/install.sh
```

Intentional non-interactive confirmation of both downloads:

```bash
./installer/install.sh --yes
```

Install or validate Runtime 1.0.0 without downloading the model:

```bash
./installer/install.sh --runtime-only
```

Install the model using an existing valid managed runtime:

```bash
./installer/install.sh --model-only
```

Validate the complete managed runtime and model without downloads:

```bash
./installer/install.sh --validate
```

Inspect and repair only missing or invalid components:

```bash
./installer/install.sh --repair
```

Use a custom managed-data location:

```bash
./installer/install.sh --install-dir "/Volumes/MySSD/LocalTranscriber"
```

Options may be combined where appropriate, for example:

```bash
./installer/install.sh --runtime-only --yes \
  --install-dir "/Volumes/MySSD/LocalTranscriber"
```

## Safety and repeatability

- Runtime downloads use the explicit `runtime-v1.0.0` GitHub Release asset.
- The archive is verified against the pinned SHA-256 before extraction.
- Runtime and model downloads are staged and validated before atomically
  replacing their managed counterparts.
- A valid existing runtime or model is not replaced during repair or reruns.
- Interrupted or failed operations clean temporary downloads and preserve the
  previous valid installation.
- `--validate` performs no downloads and returns non-zero for an invalid or
  incomplete managed environment.
- Custom runtime paths saved in LocalTranscriber are not read, changed, or
  erased by this installer.

The model is not redistributed by this repository or the GitHub Release. It is
downloaded from `mlx-community/whisper-large-v3-turbo` at the pinned revision
recorded in `runtime-manifest.json`.
