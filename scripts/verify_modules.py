#!/usr/bin/env python3
"""Generate independent arithmetic references and verify standalone retained RTL."""
import argparse
import os
from pathlib import Path
import random
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def packed(values):
    """Lane zero occupies the least significant byte."""
    return sum((value & 255) << (8 * lane) for lane, value in enumerate(values))


def verify(work):
    rng = random.Random(7)
    maxima, additions = [], []
    for case in range(512):
        values = [rng.randrange(-128, 128) for _ in range(16)]
        other = [rng.randrange(-128, 128) for _ in range(16)]
        if case == 0:
            values, other = [-128] * 16, [-128] * 16
        elif case == 1:
            values = list(range(-8, 8))
        elif case == 2:
            values, other = [127, -128] * 8, [127, -128] * 8
        elif case == 3:
            values, other = [-128, -127, -64, -1] * 4, [127] * 16
        maximum = max(values)
        deltas = [maximum - value for value in values]
        maxima.append(f'{packed(values):032x}{maximum & 255:02x}{packed(deltas):032x}')
        sums = [left + right for left, right in zip(values, other)]
        additions.append(f'{packed(values):032x}{packed(other):032x}{packed(sums):032x}')
    (work / 'max_vectors.hex').write_text('\n'.join(maxima) + '\n', encoding='ascii')
    (work / 'add_vectors.hex').write_text('\n'.join(additions) + '\n', encoding='ascii')

    cases = [
        ('tb_max_exp', 'tc_bwc_mf.v', 'tb_max_exp.sv'),
        ('tb_exponent_add', 'exponent_adder.v', 'tb_exponent_add.sv'),
    ]
    for top, source, bench in cases:
        command = [os.environ.get('IVERILOG', 'iverilog')]
        if os.environ.get('IVERILOG_LIBDIR'):
            command += ['-B', os.environ['IVERILOG_LIBDIR']]
        output = work / (top + '.vvp')
        command += ['-g2012', '-s', top, '-o', str(output),
                    str(ROOT / 'rtl' / source), str(ROOT / 'tests' / bench)]
        subprocess.run(command, check=True, timeout=90)
        result = subprocess.run([os.environ.get('VVP', 'vvp'), str(output)],
                                cwd=work, capture_output=True, text=True, timeout=90)
        log = result.stdout + result.stderr
        (work / (top + '.log')).write_text(log, encoding='utf-8')
        print(log, end='')
        if result.returncode or 'PASS:' not in log or any(
                marker in log for marker in ('FATAL:', 'ERROR:', 'WARNING:')):
            raise RuntimeError(top + ' failed')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', type=Path,
                        help='Retain vectors, simulator images and logs here')
    args = parser.parse_args()
    if args.output_dir:
        work = args.output_dir.resolve()
        work.mkdir(parents=True, exist_ok=True)
        verify(work)
    else:
        with tempfile.TemporaryDirectory(prefix='posit-modules-') as directory:
            verify(Path(directory))


if __name__ == '__main__':
    try:
        main()
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
