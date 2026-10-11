# BC250 FSR 4.1.1: default / cyboman Exact / V3 — A/B/C

STATUS: research only. Actual BC250 measurements have NOT been collected. No automatic deployment.

## Variant isolation

- default: original BC250 Proton/OptiScaler RC11 + existing gfx1013 async RADV.
- cyboman: SAME driver + exact SPIR-V shader override generated from the ACTIVE Proton game dump.
- v3: original shaders + per-user V3 RADV ICD from a separately tested compatible build.
- No combined mode until the isolated modes are validated.
- Never change system Mesa, install random DLLs globally, or use anti-cheat/online games.

WARNING: the current BC250 fsr411f provider may differ from AMD original FSR 4.1.1.2740.
cyboman overrides rely on exact original shader hashes. Silent shader-override
mismatch looks like success but yields baseline performance.

## Prepare this research branch

    git clone --depth 1 -b research/fsr4-three-way-bench \
      https://github.com/hashbolic/bc250-framework.git "$HOME/bc250-fsr4-lab"

Until the signed Framework has this feature, invoke the cloned shell script.
In Steam use a single-player DX12 Cyberpunk 2077 build with the existing
protonge-latest-bc250 runner. Record the runner version and source commit.

## Prepare cyboman Exact

1. Clone https://github.com/zgauthier2000/fsr4-shader-performance-overrides
   and record the commit SHA.
2. In OptiScaler confirm actual INT8 FSR4 provider, DLL and version.
3. Temporarily dump shaders from the SAME game and Proton with per-game
   Steam option VKD3D_SHADER_DUMP_PATH=Z:/home/YOU/fsr4-dump %command%.
4. On the cloned cyboman repo run:

    ./tools/build_override.sh /home/YOU/fsr4-dump /home/YOU/fsr4-exact-overrides

5. If no shaders match, STOP. Do not claim that cyboman was applied.
6. Generated SPIR-V files must pass spirv-val. Visual/numeric checks remain
   necessary: valid SPIR-V alone does not prove byte-identical output.

Never use lossless and lossy variants interchangeably, and never use
the prebuilt shaders on BC250 without translation-layout verification.

## Prepare V3

Follow https://github.com/dmorazasanchez/bc250-fsr4/tree/v3
(the upstream build-anywhere.sh, setup.sh, check.sh flow).

The upstream prebuilt V3 shared object targets specific CachyOS/Arch
glibc and LLVM dependencies. Bazzite may require source-built Mesa/RADV.
Keep the driver in the HOME directory with its own Vulkan ICD JSON.
Confirm it still exposes a correct, usable GFX1013 compute queue.
The wrapper tests the PCI ID, library/ABI resolution and vulkaninfo.
That does NOT prove GPU/async or FSR4 correctness.

## Run three modes in Steam

Replace YOU with the actual desktop username. Only use ONE line at a time.
For default:

    bash /home/YOU/bc250-fsr4-lab/lib/fsr4-bench.sh launch default -- %command%

For cyboman exact:

    BC250_FSR4_CYBOMAN_DIR=/home/YOU/fsr4-exact-overrides bash /home/YOU/bc250-fsr4-lab/lib/fsr4-bench.sh launch cyboman -- %command%

For V3:

    BC250_FSR4_V3_ICD=/home/YOU/.local/share/bc250-fsr4/v3/radv-bc250-fsr4-v3.json bash /home/YOU/bc250-fsr4-lab/lib/fsr4-bench.sh launch v3 -- %command%

For Lutris (our Cyberpunk installation), enable Advanced options in the game config,
then System options > Command prefix. Give the prefix **without** Steam's %command%:

    bash /home/YOU/bc250-fsr4-lab/lib/fsr4-bench.sh launch default --

For cyboman or V3, replace the word default with cyboman or v3, and
in that game's System options > Environment variables set respectively:
BC250_FSR4_CYBOMAN_DIR=/home/YOU/fsr4-exact-overrides
or BC250_FSR4_V3_ICD=/home/YOU/.../radv-bc250-fsr4-v3.json.
Lutris should append its existing Wine/umu game command after this prefix.
Keep protonge-latest-bc250 as the runner for all tests. Remove the prefix
after testing. This Lutris prefix path is proposed but not hardware-tested.

## Test protocol

- BC250 qualified 36CU; same CPU/GPU clocks, same fan curves and governor.
- Same Cyberpunk 2077 build, scene/path/graphics settings and Proton version.
- 1920x1080 FSR4 Balanced, FG OFF, VSync OFF, no FPS cap.
- Warm up shader cache and clocks. Record 3 repetitions of 45–90 seconds
  each per mode. Counterbalance test order across rounds.
- MangoHud: toggle logging at benchmark start/end (default Shift_L+F2);
  wrapper records per-mode logs and context metadata. Do not start logging
  during loading screens or menu transitions.
- Compare mean FPS, 1% low, P99 frametime, and the OptiScaler per-upscale time.
- Visual QA: fine fences, signage, bottles, cables, reflections, moving grass,
  bright particles, ghosting, brightness/flicker changes.
- Check for GPU hangs, amdgpu log errors, WGP artifacts and clock throttling.

Summarize raw captures with:

    python3 "$HOME/bc250-fsr4-lab/helpers/fsr4_bench_report.py" \
      "$HOME/.local/share/bc250-framework/fsr4-bench"

This reports real captured values, never generated FPS. No result is final
unless at least 3 equivalent runs per mode, correct shader/driver active
and visual quality/correctness are independently verified.

## Possible fourth path: BC250 V4 research

- Tune FSR4 signed-dot lowering using actual spills, register pressure and
  occupancy instead of only hardcoded shader-family SDot counts.
- Revisit cyboman postpass LDS/store changes on gfx1013 at 1080p; RDNA2
  can regress at lower output resolution, so consider conditional fallback.
- Use shader-family-by-family ACO statistics to identify optimization wins.
- Once separate tests pass, test V3 + verified exact cyboman overrides together.
- No frame-skipping, weight pruning or changed-quality lossy optimizations.

Rollback: remove the per-game launch option. No system Mesa or game DLL
is overwritten by this benchmark harness.
