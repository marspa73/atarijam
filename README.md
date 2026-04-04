
# JAM (Just Atari Model) Release

🕹️ Is this the smallest language model in the world? 
Who knows but it is a fully generative, deterministic language model, powered by a neural network.
Real silicon intelligence in 2-80 kilobytes, running on a 1979 Atari 800.


Three Atari language models, ready to build and ready to run:

- `picojam`: ultra-tiny 8-bit proof, about `1.6 KB` brain
- `jam`: compact standalone JAM, about `18 KB` brain
- `jamxe`: bank-switched Atari 130XE model, about `77.7 KB` brain

 <img width="2131" height="1538" alt="image" src="https://github.com/user-attachments/assets/db6cf9ef-51df-492a-aa3c-05ea9e4658b1" />


Each project folder contains:

- source `.asm`
- current training data
- current trained weight blob
- a prebuilt `.xex` in `dist/`
- a portable `build.py`
- a trainer script for optional retraining

  <img width="1094" height="811" alt="image" src="https://github.com/user-attachments/assets/b154509c-1786-4040-ace2-f56770bcd78a" />


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

Build all three from the shipped weights:

```powershell
python build_all.py
```

Build a single model:

```powershell
python picojam\build.py
python jam\build.py
python jamxe\build.py
```

Retrain and rebuild:

```powershell
python picojam\build.py --train
python jam\build.py --train
python jamxe\build.py --train
```

## Included Binaries

- [picojam/dist/picojam.xex](/C:/j/atari/jam-release/picojam/dist/picojam.xex)
- [jam/dist/jam.xex](/C:/j/atari/jam-release/jam/dist/jam.xex)
- [jamxe/dist/jamxe.xex](/C:/j/atari/jam-release/jamxe/dist/jamxe.xex)

## Project Notes

### `picojam`

Smallest of the three. Fast, weird, and fun.

### `jam`

Compact general JAM release. Strong personality, simple standalone build, no bank switching.

### `jamxe`

Main high-end Atari XE line. Uses bank-switched memory and the richest runtime.



Copyright (c) 2026 jam.ag / Marek Spanel

**LICENSE MIT:** Do whatever you want, just keep my name and don’t blame me.

