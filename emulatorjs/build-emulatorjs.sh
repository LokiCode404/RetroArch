#!/bin/bash
set +e

. ../version.all

if [[ -z "$EMSCRIPTEN" ]] ; then
  echo "Run this script with emmake. Ex: emmake $0"
  exit 1
fi

for i in "$@"; do
  case $i in
    --threads)
      PTHREADS=YES
      shift
      ;;
    --legacy)
      LEGACY=YES
      shift
      ;;
    --clean)
      CLEAN=YES
      shift
      ;;
    *)
      echo "Unknown option $i"
      echo "Usage: $0 [option] ..."
      echo "Options:"
      echo "  --threads"
      echo "  --legacy"
      echo "  --clean"
      exit 1
      ;;
  esac
done

clean () {
  make -C ../ -f Makefile.emulatorjs clean || exit 1
}
containsElement () {
  local e match="$1"
  shift
  for e; do
    if [[ "$e" == "$match" ]]; then
      echo 1
      return 0
    fi
  done
  echo 0
  return 1
}

if [[ "$CLEAN" = "YES" ]]; then
  clean
fi

lastGles=0

largeStack=("mupen64plus_next" "azahar")
largeHeap=("mupen64plus_next" "picodrive" "pcsx_rearmed" "genesis_plus_gx" "genesis_plus_gx_wide" "mednafen_psx" "mednafen_psx_hw" "parallel_n64" "ppsspp" "azahar")
needsGles3=("ppsspp" "azahar")
needsThreads=("ppsspp" "azahar")
largeThreads=("ppsspp" "azahar")
noCHD=("mame2003" "mame2003_plus" "pcsx_rearmed" "genesis_plus_gx" "genesis_plus_gx_wide" "azahar")
no7Zip=("bsnes")
# Cores that use minimal asyncify (ASYNCIFY_IGNORE_INDIRECT + ASYNCIFY_REMOVE)
# instead of full asyncify for better performance. Only functions in the
# init/load call chain (fopen→TinyXML→machineCreate) need async support;
# the CPU hot loop, VDP, audio mixer, and slot manager are excluded.
minAsync=("bluemsx")

for f in $(ls -v *_emscripten.bc); do
  name=`echo "$f" | sed "s/\(_libretro_emscripten\|\).bc$//"`
  async=1
  min_async=0
  sevenZip=1
  wasm=1
  gles3=1
  stack_mem=4194304 # 4mb
  heap_mem=134217728 # 128mb
  pthread=0
  chd=1
  threads=0
  asyncify_remove=""

  if [ "$LEGACY" = "YES" ]; then
    gles3=0
  fi

  if [[ "$PTHREADS" = "YES" ]]; then
    threads=1
    pthread=4
  fi

  if [[ $(containsElement $name "${largeStack[@]}") = 1 ]]; then
    stack_mem=134217728 # 128mb
  fi
  if [[ $(containsElement $name "${largeHeap[@]}") = 1 ]]; then
    heap_mem=536870912 # 512mb
  fi
  if [[ $(containsElement $name "${needsThreads[@]}") = 1 && $pthread = 0 ]]; then
    echo "$name"' requires threads! Please build with --threads! Exiting...'
    exit 1
  fi
  if [[ $(containsElement $name "${noCHD[@]}") = 1 ]]; then
    chd=0
  fi
  if [[ $(containsElement $name "${largeThreads[@]}") = 1 ]]; then
    pthread=32
  fi
  if [[ $(containsElement $name "${no7Zip[@]}") = 1 ]]; then
    sevenZip=0
  fi
  if [[ $(containsElement $name "${needsGles3[@]}") = 1 && $gles3 = 0 ]]; then
    echo "$name"' does not support gles2 (legacy)! Please build without --legacy! Exiting...'
    exit 1
  fi

  # blueMSX: use minimal asyncify to exclude CPU/VDP/audio hot paths
  if [[ $(containsElement $name "${minAsync[@]}") = 1 ]]; then
    async=0
    min_async=1
    # Exclude the entire Z80/R800 CPU execution engine, VDP scanline
    # renderers, audio mixer inner loops, and memory slot manager from
    # Asyncify instrumentation. These functions are called millions of
    # times per second and never perform I/O that needs to yield.
    # Glob patterns (wildcards) match all variants of each prefix.
    asyncify_remove='"*r800Execute*","*r800ExecuteUntil*","*executeInstruction*","*readMem*","*writeMem*","*readOpcode*","*readPort*","*writePort*","*cb*","*dd*","*ed*","*fd*","*dd_cb*","*fd_cb*","*INC*","*DEC*","*ADD*","*ADC*","*SUB*","*SBC*","*AND*","*OR*","*XOR*","*CP*","*SLA*","*SRA*","*SRL*","*SLL*","*RLC*","*RRC*","*RL*","*RR*","*ADDW*","*ADCW*","*SBCW*","*MULU*","*MULUW*","*vdpRefreshLine*","*RefreshLine*","*updateSprites*","*colorSpriteLine*","*mixerSync*","*slotRead*","*slotWrite*","*slotPeek*","*slotMapPage*","*boardTimer*","*ay8910*","*sn76489*","*sccUpdate*","*ym2413*","*OPL*","*Fmopl*"'
  fi

  echo "-- Building core: $name --"
  cp -f "$f" ../libretro_emscripten.a
   
  echo NAME: $name
  echo ASYNC: $async
  echo HAVE_THREADS: $threads
  echo PTHREAD_POOL_SIZE: $pthread
  echo GLES3: $gles3
  echo STACK_SIZE: $stack_mem
  echo INITIAL_HEAP: $heap_mem
  echo HAVE_CHD: $chd
  echo HAVE_7ZIP: $sevenZip

  if [[ "$CLEAN" = "YES" ]]; then
    if [ $lastGles != $gles3 ] ; then
        clean
    fi
  fi
  lastGles=$gles3

  # Compile core
  if [[ $min_async = 1 ]]; then
    # --- DUAL BUILD for minAsync cores (e.g. blueMSX) ---
    # Build 1: JSPI → bluemsx-wasm.data (zero overhead, Chrome 123+/Firefox 132+)
    # Build 2: MIN_ASYNC → bluemsx-legacy-wasm.data (fallback for Safari/old browsers)
    # EmulatorJS detects JSPI support via WebAssembly.Suspending and selects
    # the right variant (patched in emulator.js).

    # --- Build 1: JSPI (non-legacy slot) ---
    echo "=== BUILD 1/2: JSPI build for $name ==="
    emmake make -C ../ -f Makefile.emulatorjs clean 2>/dev/null
    make -C ../ -f Makefile.emulatorjs \
      HAVE_7ZIP=$sevenZip HAVE_CHD=$chd \
      HAVE_THREADS=$threads PTHREAD_POOL_SIZE=$pthread \
      USE_JSPI=1 \
      HAVE_OPENGLES3=$gles3 \
      STACK_SIZE=$stack_mem INITIAL_HEAP=$heap_mem \
      TARGET=${name}_libretro.js -j$(nproc) || exit 1

    # Package JSPI build as non-legacy (bluemsx-wasm.data)
    out_dir="../../EmulatorJS/data/cores"
    mkdir -p $out_dir
    core=${name}
    if [ $name = "mednafen_vb" ]; then core="beetle_vb"; fi
    jspi_out="${core}-wasm.data"
    7z a ${out_dir}/${jspi_out} ../${name}_libretro.wasm ../${name}_*.js
    rm -f ../${name}_libretro.wasm ../${name}_libretro.js

    # --- Build 2: MIN_ASYNC (legacy slot) ---
    echo "=== BUILD 2/2: MIN_ASYNC fallback build for $name ==="
    emmake make -C ../ -f Makefile.emulatorjs clean 2>/dev/null
    make -C ../ -f Makefile.emulatorjs \
      HAVE_7ZIP=$sevenZip HAVE_CHD=$chd \
      HAVE_THREADS=$threads PTHREAD_POOL_SIZE=$pthread \
      HAVE_AL=0 HAVE_RWEBAUDIO=1 \
      MIN_ASYNC=1 \
      ASYNCIFY_REMOVE="$asyncify_remove" \
      HAVE_OPENGLES3=0 \
      STACK_SIZE=$stack_mem INITIAL_HEAP=$heap_mem \
      TARGET=${name}_libretro.js -j$(nproc) || exit 1

    # Package MIN_ASYNC build as legacy (bluemsx-legacy-wasm.data)
    legacy_out="${core}-legacy-wasm.data"
    7z a ${out_dir}/${legacy_out} ../${name}_libretro.wasm ../${name}_*.js
    rm -f ../${name}_libretro.wasm ../${name}_libretro.js
  else
    echo "BUILD COMMAND: make -C ../ -f Makefile.emulatorjs HAVE_7ZIP=$sevenZip HAVE_CHD=$chd HAVE_THREADS=$threads PTHREAD_POOL_SIZE=$pthread ASYNC=$async HAVE_OPENGLES3=$gles3 STACK_SIZE=$stack_mem INITIAL_HEAP=$heap_mem TARGET=${name}_libretro.js -j"$(nproc)
    make -C ../ -f Makefile.emulatorjs HAVE_7ZIP=$sevenZip HAVE_CHD=$chd HAVE_THREADS=$threads PTHREAD_POOL_SIZE=$pthread ASYNC=$async HAVE_OPENGLES3=$gles3 STACK_SIZE=$stack_mem INITIAL_HEAP=$heap_mem TARGET=${name}_libretro.js -j$(nproc) || exit 1

    # Move executable files
    out_dir="../../EmulatorJS/data/cores"
    out_name=""

    mkdir -p $out_dir

    core=""
    if [ $name = "mednafen_vb" ]; then
      core="beetle_vb"
    else
      core=${name}
    fi

    out_name=${core}

    if [[ $pthread != 0 ]] ; then
      out_name="${out_name}-thread"
    fi
    if [[ $gles3 = 0 ]] ; then
      out_name="${out_name}-legacy"
    fi
    out_name="${out_name}-wasm.data"

    if [ $wasm = 0 ]; then
      7z a ${out_dir}/${out_name} ../${name}_libretro.js.mem ../${name}_*.js
      rm ../${name}_libretro.js.mem
    else
      7z a ${out_dir}/${out_name} ../${name}_libretro.wasm ../${name}_*.js
      rm ../${name}_libretro.wasm
    fi
    rm -f ../${name}_libretro.js
  fi
done
