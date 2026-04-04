#!/usr/bin/env python3
"""Generate a theme include from @title/@sub/@sug in training data."""
import sys

def _strip_try_prefix(s):
    s = s.strip()
    if s.upper().startswith('TRY '):
        return s[4:].strip()
    return s

def _center32(s):
    s = s[:32]
    pad = max(0, (32 - len(s)) // 2)
    return (' ' * pad + s)[:32]

def _icon_sig_line(sig_text):
    sig_text = sig_text[:30]
    visible = 2 + len(sig_text)  # "> " + text
    left = max(0, (32 - visible) // 2)
    right = max(0, 32 - visible - left)
    return left, sig_text, right

def gen(datafile, outfile='theme.inc'):
    title = 'JAM'
    subs = []
    sugs = []
    dreams = []
    size = '30'
    brain = ''
    with open(datafile) as f:
        for line in f:
            line = line.strip()
            if line.startswith('@title '):
                title = line[7:].strip()
            elif line.startswith('@sub '):
                subs.append(line[5:].strip())
            elif line.startswith('@sug '):
                sugs.append(line[5:].strip()[:15])
            elif line.startswith('@dream '):
                dreams.append(line[7:].strip()[:15])
            elif line.startswith('@size '):
                size = line[6:].strip()
            elif line.startswith('@brain '):
                brain = line[7:].strip()
    if not sugs:
        sugs = ['HELP'] * 8
    while len(sugs) < 8:
        sugs.append(sugs[len(sugs) % len(sugs)])
    sugs = sugs[:8]

    if not dreams:
        dreams = sugs[:]
    while len(dreams) < 16:
        dreams.append(dreams[len(dreams) % len(dreams)])
    dreams = dreams[:16]

    hint_words = [_strip_try_prefix(s)[:8] for s in sugs]
    sub_has_prompt = any(sub.lower().startswith(('try:', 'ask:', 'more:')) for sub in subs)
    if sub_has_prompt:
        hint_lines = []
    else:
        hint_lines = ['Ask: ' + ' '.join(hint_words[:4])]
        if len(hint_words) > 4:
            hint_lines.append('More: ' + ' '.join(hint_words[4:8]))
    title_line = _center32(title.upper())
    model_line = _center32('JUST ATARI LANGUAGE MODEL')
    sig_text = 'jam.ag / Marek Spanel'
    sig_left, sig_text, sig_right = _icon_sig_line(sig_text)
    lines = []
    lines.append('; Auto-generated from training data. Do not edit.')
    lines.append('ban:')
    lines.append('        .byte $7D  ; clear screen')
    lines.append('        .byte "================================", $9B')
    lines.append(f'        .byte "{title_line}", $9B')
    lines.append(f'        .byte "{model_line}", $9B')
    lines.append(f'        .byte "{" " * sig_left}", $BE, " {sig_text}{" " * sig_right}", $9B')
    lines.append('        .byte "================================", $9B')
    if brain:
        lines.append(f'        .byte "{_center32(f"{size} KB / {brain} KB brain on 6502")}", $9B')
    else:
        lines.append(f'        .byte "{_center32(f"{size} KB on 6502 at 1.79 MHz")}", $9B')
    lines.append(f'        .byte "{_center32("No lookup. Pure generation.")}", $9B')
    lines.append('        .byte $9B')
    lines.append('banl = * - ban')
    lines.append('')
    lines.append('intro:')
    for sub in subs:
        sub = sub[:38]
        lines.append(f'        .byte "{sub}", $9B')
    for hint in hint_lines:
        hint = hint[:38]
        lines.append(f'        .byte "{hint}", $9B')
    lines.append('        .byte $9B')
    lines.append('introl = * - intro')
    lines.append('')
    lines.append('; === Proactive suggestions (theme-specific) ===')
    for i, s in enumerate(sugs):
        lines.append(f'sug{i}:   .byte "{s}"')
        lines.append(f'sug{i}l = * - sug{i}')
    lines.append('sug_ptrs: .word ' + ', '.join(f'sug{i}' for i in range(8)))
    lines.append('sug_lens: .byte ' + ', '.join(f'sug{i}l' for i in range(8)))
    lines.append('')
    lines.append('; === Dream seeds (16 entries for idle_chatter) ===')
    for i, d in enumerate(dreams):
        lines.append(f'drm{i}:   .byte "{d}"')
        lines.append(f'drm{i}l = * - drm{i}')
    lines.append('drm_ptrs: .word ' + ', '.join(f'drm{i}' for i in range(16)))
    lines.append('drm_lens: .byte ' + ', '.join(f'drm{i}l' for i in range(16)))
    with open(outfile, 'w') as f:
        f.write('\n'.join(lines) + '\n')
    print(f'  {outfile}: "{title}", {len(subs)} sub, {len(sugs)} sug, {len(dreams)} dream')

if __name__ == '__main__':
    datafile = sys.argv[1] if len(sys.argv) > 1 else 'td_animals.txt'
    outfile = sys.argv[2] if len(sys.argv) > 2 else 'theme.inc'
    gen(datafile, outfile)
