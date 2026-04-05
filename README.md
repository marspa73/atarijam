
# JAM (Just Atari Model) Release

Is this the smallest language model in the world?
Who knows but it is a fully generative, deterministic language model, powered by a neural network.
Real silicon intelligence in 2-80 kilobytes, running on a 1979 Atari 800.


Six Atari language models, ready to build and ready to run:

- `picojam`: ultra-tiny 8-bit proof, about `1.6 KB` brain
- `jam`: compact standalone JAM, about `18 KB` brain
- `jamxe`: bank-switched Atari 130XE model, about `76 KB` brain
- `jamkid`: same 130XE runtime, kid personality
- `picosam`: picojam + experimental POKEY tone output
- `jamsam`: jam + experimental POKEY tone output

 <img width="2131" height="1538" alt="image" src="https://github.com/user-attachments/assets/db6cf9ef-51df-492a-aa3c-05ea9e4658b1" />


Each project folder contains:

- source `.asm` (or shared from `jamxe/`)
- current training data
- current trained weight blob
- a prebuilt `.xex` in `dist/`
- a portable `build.py`
- a trainer script for optional retraining

`jamxe` and `jamkid` also include `.atr` disk images for SIO2SD.

<img width="1267" height="1206" alt="image" src="https://github.com/user-attachments/assets/62e499a8-106a-4361-97d5-029cb16daa9d" />



## Requirements

For building:

- Python 3.10+
- `ca65` and `ld65` from `cc65`

For retraining:

- Python 3.10+
- `torch`

The build scripts try `ca65/ld65` from:

1. your `PATH`
2. a sibling local toolchain at `../tools/cc65/bin`

## Quick Start

Build all from the shipped weights:

```powershell
python build_all.py
```

Build a single model:

```powershell
python picojam\build.py
python jam\build.py
python jamxe\build.py
python jamkid\build.py
python picosam\build.py
python jamsam\build.py
```

Retrain and rebuild:

```powershell
python picojam\build.py --train
python jam\build.py --train
python jamxe\build.py --train
python jamkid\build.py --train
```

The SAM variants (`picosam`, `jamsam`) share training data with their base models.

## Included Binaries

- [picojam/dist/picojam.xex](picojam/dist/picojam.xex)
- [jam/dist/jam.xex](jam/dist/jam.xex)
- [jamxe/dist/jamxe.xex](jamxe/dist/jamxe.xex)
- [jamxe/dist/jamxe.atr](jamxe/dist/jamxe.atr) (SIO2SD)
- [jamkid/dist/jamkid.xex](jamkid/dist/jamkid.xex)
- [jamkid/dist/jamkid.atr](jamkid/dist/jamkid.atr) (SIO2SD)
- [picosam/dist/picosam.xex](picosam/dist/picosam.xex)
- [jamsam/dist/jamsam.xex](jamsam/dist/jamsam.xex)

## SIO2SD Notes

The `.atr` images boot directly from the SD card. Setup:

1. Copy `.atr` to SD card
2. Assign to **D1:** slot
3. **Disable SIO2SD** (important!)
4. Power on / reset the Atari — it boots from the ATR

## Project Notes

### `picojam`

Smallest of them all. Fast, weird, and fun.

### `jam`

Compact general JAM release. Strong personality, simple standalone build, no bank switching.

### `jamxe`

Main high-end Atari XE line. Uses bank-switched 130XE memory,
512-input frozen query anchor, D/J context attention, incremental
L1 with bank-major delta normalization.

### `jamkid`

Same 130XE runtime as `jamxe`, different personality.
A small, curious, playful machine child. Shares ASM and packer with `jamxe/`.

### `picosam`

Experimental: picojam with POKEY tone output. Each generated character
produces a formant-like tone via POKEY. Proof of concept, not real speech.

### `jamsam`

Experimental: jam with POKEY tone output on channels 2-4.
Channel 1 stays free for the thinking sound. Same proof of concept as picosam.


Copyright (c) 2026 jam.ag / Marek Spanel

**LICENSE MIT:** Do whatever you want, just keep my name and don't blame me.

