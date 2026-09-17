# T.800 reversible-exponent evidence

Verified against [ITU-T T.800 (11/2015), official PDF](https://www.itu.int/rec/dologin_pub.asp?id=T-REC-T.800-201511-S%21%21PDF-E&lang=e&type=items). Equations and tables were visually checked. This note summarizes the requested passages; it does not reproduce them in full.

## Finding

Reversible decoding is E.1.2, not E.1.1. The encoder equation is E-10, in E.2, explicitly titled **“Scalar coefficient quantization (informative)”**. Its wording includes **“has to be recorded”** and **“and is calculated as:”**.

```text
E-2:   M_b = G + ε_b − 1
E-4:   R_b = R_I + log2(gain_b)
E-10:  ε_b = R_I + log2(gain_b) + ζ_c
```

E-2 uses G and ε_b from QCD/QCC. ζ_c accounts for RCT bit growth; without RCT it is zero. E.1.2.1 sets Δ_b=1.

Table E.1:

| Band | gain_b | log2(gain_b) |
|---|---:|---:|
| LL | 1 | 0 |
| HL | 2 | 1 |
| LH | 2 | 1 |
| HH | 4 | 2 |

A.6.4 uses **A.29** for reversible exponents; A.30 concerns irreversible quantization. A.29 places ε_b in bits 7–3: `ε_b = SPqcd >> 3`. Its printed E-5 cross-reference appears inconsistent.

A.5.1/A.11 defines `R_I = (Ssiz & 0x7f)+1`, including the sample sign bit when applicable.

Locate printed pages **23, 29, 107–109** (PDF pages **31, 37, 115–117**, counting from 1).

## Validator decision (inference)

These passages do not establish the proposed mandatory equality check. Keep mismatch as a WARN candidate, pending a separate normative basis. Do not promote the seven `p0_13` survivors to FAIL solely from E-10. Their files were not inspected here.
