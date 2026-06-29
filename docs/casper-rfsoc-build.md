# Building the RFSoC 4x2 CASPER gateware (headless)

This guide documents how to build the CASPER/RFSoC bitstream that feeds the
DAQIRI-MIXER correlator with real ADC data, **without the Simulink GUI** — the
whole toolflow is driven from a script over ssh.

The reference design is `rfsoc4x2_stream_rfdc_100g` (one raw ADC streamed over
100 GbE). The same procedure rebuilds any modified design — see
[Editing the design](#editing-the-design).

---

## Why it has to run on `acme2`

CASPER is **not** an open toolflow. A `.fpg` bitstream requires two proprietary
tools, and there is no open-source replacement (yosys/nextpnr do not target
Zynq UltraScale+ RFSoC):

| Stage | Tool | Notes |
|-------|------|-------|
| Design front-end | MATLAB + Simulink + Xilinx **Model Composer** (System Generator) | draws/elaborates the yellow blocks |
| Synthesis / P&R / bitstream | Xilinx **Vivado** | the RFDC and 100G CMAC are hard IP, Vivado-only |

- **`acme2`** (`10.0.1.23`) has the working, version-matched toolchain:
  MATLAB **R2021a**, Vivado **2021.1**, Model Composer **2021.1**, and the
  CASPER `mlib_devel` (branch `my_m2021a`) configured in
  `~/src/mlib_devel/startsg.local`. This is the build box.
- The **digilab box** (where DAQIRI-MIXER runs) has Vivado 2025.1 but **no
  MATLAB**, and 2025.1 is newer than this `mlib_devel` was validated against.
  It cannot build CASPER. Do the build on `acme2`, copy the `.fpg` to wherever
  the board is controlled from.

> Building a *new/modified* design still needs the Simulink GUI (or the
> scripted model-edit API) on `acme2`; only the **compile** is headless.

---

## Prerequisites

1. **ssh access to acme2 with your key in the agent.** From the digilab box:
   ```bash
   source ~/.ssh/agent.env      # loads the ed25519 key into ssh-agent ("the keyring")
   ssh acme2 'hostname'         # should print acme2
   ```
2. **The CASPER tutorials checkout** on acme2:
   `~/src/tutorials_devel/rfsoc/tut_onehundred_gbe/rfsoc4x2_stream_rfdc_100g.slx`
3. **The toolflow env file** `~/src/mlib_devel/startsg.local` (already present),
   which sets `MATLAB_PATH`, `XILINX_PATH`, `COMPOSER_PATH`,
   `JASPER_BACKEND=vitis`, `XLNX_DT_REPO_PATH`.

### One-time: the Python venv

The toolflow's Python backend imports `odict numpy pyaml colorlog six lxml`
(`mlib_devel/requirements.txt`); the system `python` lacks them. Create a venv
once:

```bash
ssh acme2 '
  python3 -m venv ~/casper_venv
  ~/casper_venv/bin/pip install -U pip
  ~/casper_venv/bin/pip install -r ~/src/mlib_devel/requirements.txt
  ~/casper_venv/bin/python -c "import odict,numpy,yaml,colorlog,six,lxml; print(\"deps OK\")"
'
```

---

## The build script

A reusable, parameterized script lives at `acme2:~/casper_build.sh` (a copy is
kept in this repo at [`scripts/casper_build.sh`](../scripts/casper_build.sh)).
It replicates the environment that the interactive `startsg` launcher exports,
then drives `model_composer` in batch mode under a virtual display:

```bash
#!/bin/bash
# usage: ./casper_build.sh <MODEL_NAME> [MODEL_DIR]
MODEL="${1:?need model name}"
MODELDIR="${2:-$HOME/src/tutorials_devel/rfsoc/tut_onehundred_gbe}"
MLIB="$HOME/src/mlib_devel"
cd "$MLIB"
source ./startsg.local
export MLIB_DEVEL_PATH="$MLIB" MATLAB="$MATLAB_PATH" CASPER_BASE_PATH="$MLIB"
export HDL_ROOT="$MLIB/jasper_library/hdl_sources"
export XPS_BASE_PATH="$MLIB/xps_base"
export SYSGEN_SCRIPT="$MLIB/startsg"
export PATH="$MATLAB_PATH/bin:$PATH"
source "$COMPOSER_PATH/settings64.sh" >/dev/null 2>&1
export PATH="$COMPOSER_PATH/bin:$PATH"
source "$HOME/casper_venv/bin/activate"          # casper python deps; LAST so its python wins
MS="addpath('$MODELDIR'); cd('$MODELDIR'); try, jasper('$MODEL'); disp('JASPER_DONE_OK'); \
    catch e, disp('JASPER_FAILED:'); disp(getReport(e)); end; bdclose('all'); exit"
xvfb-run -a -s "-screen 0 1280x1024x24" \
  model_composer -matlab "$MATLAB_PATH" -nodesktop -nosplash -r "$MS"
```

### Three things that make headless work (and why)

These are the non-obvious bits — get them wrong and the build fails in three
distinct ways:

1. **`-nodesktop`, not `-nodisplay`, under `xvfb-run`.** System Generator's
   "Generate" step (`xlGenerateButton`) pops a Java wait-box. With
   `-nodisplay` MATLAB is headless and it throws
   `java.awt.HeadlessException`. `xvfb-run` gives MATLAB a virtual X display so
   `-nodesktop` (no IDE, but AWT/Swing still render) works.
2. **Replicate the full `startsg` export set.** The Python backend
   (`exec_flow.py`) reads `HDL_ROOT`, `SYSGEN_SCRIPT`, `MLIB_DEVEL_PATH`,
   `XILINX_PATH`, `XLNX_DT_REPO_PATH`. `startsg.local` only sets some; export the
   rest or you get `AttributeError: 'NoneType' ... HDL_ROOT`.
3. **Activate the venv last.** The toolflow shells out to `python`; that must
   resolve to `~/casper_venv` (which has `odict` et al.), not `/usr/bin/python`.
   Sourcing `activate` last puts the venv first on `PATH`.

`bdclose('all'); exit` avoids the interactive "Save model before closing?"
prompt that otherwise hangs batch mode.

---

## Running a build

A full RFSoC 4x2 build is ~20 min on acme2 (48 cores). Run it detached so an
ssh drop doesn't kill it:

```bash
source ~/.ssh/agent.env
MODEL=rfsoc4x2_stream_rfdc_100g
ssh acme2 "setsid nohup ~/casper_build.sh $MODEL > ~/$MODEL.buildlog 2>&1 </dev/null & echo PID \$!"
```

(Optional **fast sanity probe** before committing — just loads the model
headless, ~1 min; if it prints `LOADED_OK` the license/SysGen/display chain is
fine:)

```bash
ssh acme2 'cd ~/src/mlib_devel && source ./startsg.local && export MATLAB="$MATLAB_PATH" \
  && PATH="$MATLAB_PATH/bin:$PATH" && source "$COMPOSER_PATH/settings64.sh" >/dev/null \
  && xvfb-run -a model_composer -matlab "$MATLAB_PATH" -nodesktop -nosplash \
     -r "addpath(\"$HOME/src/tutorials_devel/rfsoc/tut_onehundred_gbe\"); \
         load_system(\"rfsoc4x2_stream_rfdc_100g\"); disp(\"LOADED_OK\"); exit"'
```

### Monitor

```bash
ssh acme2 'L=~/rfsoc4x2_stream_rfdc_100g.buildlog
  grep -nE "Frontend complete|launch_runs|write_bitstream|JASPER_DONE_OK|JASPER_FAILED" $L | tail
  tail -5 $L'
```

Phases you will see in order: `Frontend complete` → `create_project ... -part
xczu48dr-ffvg1517-2-e` → `launch_runs synth_1` → `write_bitstream` →
`Backend complete!` → `JASPER_DONE_OK`.

---

## Output & verification

On success the artifacts land in
`<MODEL_DIR>/<MODEL>/outputs/<MODEL>_<date>.fpg` (and `.dtbo`):

```bash
ssh acme2 'ls -l ~/src/tutorials_devel/rfsoc/tut_onehundred_gbe/rfsoc4x2_stream_rfdc_100g/outputs/'
```

The `.fpg` is a text metadata header (register/block map) followed by the
gzipped bitstream. Sanity-check the register map:

```bash
ssh acme2 'strings <FPG> | grep "^?register" | awk "{print \$2}" | sort -u | head'
# expect: rfdc, onehundred_gbe, adc_chan_sel, pkt_rst, sys_*, ...
```

A faithful rebuild of `stream_rfdc` has a register map **identical** to
`prebuilt/rfsoc4x2/rfsoc4x2_tut_100g_stream_rfdc.fpg`.

---

## Programming the board

Programming uses **`casperfpga`** (open, pure-Python — `pip install casperfpga`),
so this part does *not* need MATLAB/Vivado:

```python
import casperfpga
fpga = casperfpga.CasperFpga('rfsoc4x2')          # board hostname/IP
fpga.upload_to_ram_and_program('<MODEL>_<date>.fpg')
fpga.write_int('adc_chan_sel', 0)                 # pick ADC 0..3
# set dest MAC/IP/port on the onehundred_gbe block, then it streams.
```

The wire format produced (for the RX side): `eth(14)+ip(20)+udp(8)=42`, then a
64-byte header with **seq = uint64 little-endian at byte 42**, then payload at
**byte 106** = 2048 complex samples (int16 I + int16 Q, oldest first). See the
tutorial's `py/tut_100g_listener.py` for the authoritative parser.

---

## Editing the design

To change the gateware (e.g. **4 simultaneous ADC inputs**, or **int8
requantize** to fit four inputs in 100 GbE), edit the `.slx` on acme2 — either
in the Model Composer GUI, or via MATLAB's scriptable Simulink API
(`add_block` / `set_param` / `add_line` / `save_system`) for parameter-level
changes. Then rebuild with the **same** `casper_build.sh <new-model-name>`.

The packetizer in `rfsoc4x2_stream_rfdc_100g` is intentionally simple
(munge → ping-pong 256→512 S/P → FIFO of 128 words → 64-byte counter header →
100GbE), which is what makes these edits tractable.
