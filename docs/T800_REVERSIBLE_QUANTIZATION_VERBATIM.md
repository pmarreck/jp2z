# T.800 (11/2015): reversible quantization source extracts

## Provenance and transcription conventions (editorial)

Source supplied by Peter: `T-REC-T.800-201511-S!!PDF-E.pdf`.

SHA-256:

```text
B1CA01EECD3FE13AD58EA2E253C19274EB091E4A3E240B489941C664E96869E0
```

The PDF identifies itself as ITU-T T.800 (11/2015), common text with ISO/IEC 15444-1:2016 (E). It has 231 PDF pages. PDF page numbers below count from 1; printed page numbers refer to the numbers on the page itself.

Prose in blockquotes is transcribed verbatim from the supplied document. Line wrapping and layout spacing are normalized. Mathematical typography is represented in LaTeX; table layout is represented in Markdown. Modal wording and printed cross-references are retained, including apparent cross-reference errors. Editorial headings, omission notices, and analysis are explicitly distinguished from source text.

The requested edition-specific locations are:

| Requested material | Actual location in this PDF | Printed page | PDF page |
|---|---|---:|---:|
| Component precision and signedness | A.5.1, Table A.11 | 23 | 31 |
| QCD scope and precedence | A.6.4 | 28 | 36 |
| Quantization-style selector | Table A.28 | 29 | 37 |
| Reversible five-bit exponent | **Table A.29** | 29 | 37 |
| Irreversible exponent/mantissa | Table A.30 | 29 | 37 |
| E.1 and Equation E-2 | Annex E, E.1 | 107 | 115 |
| Definition of nominal range and subband gains | E.1.1.1, Table E.1, Equation E-4 | 107–108 | 115–116 |
| Reversible inverse quantization | **E.1.2** | 108 | 116 |
| Encoder exponent formula | **E.2 (informative), Equation E-10** | 109 | 117 |

## 1. Annex E opening and E.1 (source transcription)

Printed page 107; PDF page 115.

> Annex E
>
> Quantization
>
> (This annex forms an integral part of this Recommendation | International Standard.)

> In this annex, the flow charts and tables are normative only in the sense that they are defining an output that alternative implementations shall duplicate.

> This annex specifies the forms of inverse quantization used for the reconstruction of tile-component transform coefficients. Information about the quantization of transform coefficients for encoding is also provided. Quantization is the process by which the transform coefficients are reduced in precision.

> E.1 Inverse quantization procedure

> For each transform coefficient (u, v) of a given sub-band b, the transform coefficient value q̅_b(u, v) is given by the following equation:

\[
\overline{q}_b(u,v)
=\left(1-2s_b(u,v)\right)
\cdot\left(\sum_{i=1}^{N_b(u,v)} MSB_i(b,u,v)\cdot 2^{M_b-i}\right)
\qquad\text{(E-1)}
\]

> where s_b(u, v), N_b(u, v) and MSB_i(b, u, v) are given in D.2, and where M_b is retrieved using Equation (E-2), where the number of guard bits G and the exponent ε_b are specified in the QCD or QCC marker segments (see A.6.4 and A.6.5).

\[
M_b=G+\varepsilon_b-1
\qquad\text{(E-2)}
\]

> Each decoded transform coefficient q̅_b(u, v) of sub-band b is used to generate a reconstructed transform coefficient Rq_b(u, v), as will be described in E.1.1.

> NOTE – Decoding only N_b(u, v) (see D.2.1) bit-planes is equivalent to decoding data which has been encoded using a scalar quantizer with step size 2^{M_b−N_b(u,v)} · Δ_b for all the coefficients of this code-block. Due to the nature of the three coding passes (see D.3), N_b(u, v) may be different for different coefficients within the same code-block.

## 2. Nominal range, R_I, Table E.1 and Equation E-4 (source transcription)

Printed pages 107–108; PDF pages 115–116. These passages are under the **irreversible** subsection in this edition.

> E.1.1 Irreversible transformation
>
> E.1.1.1 Determination of the quantization step size

> For irreversible transformation, the quantization step size Δ_b for a given sub-band b is calculated from the dynamic range R_b of sub-band b, the exponent ε_b and mantissa μ_b, as given in Equation (E-3).

\[
\Delta_b=2^{R_b-\varepsilon_b}\left(1+\frac{\mu_b}{2^{11}}\right)
\qquad\text{(E-3)}
\]

> NOTE – The denominator, 2¹¹, in Equation (E-3) is due to the allocation of 11 bits in the codestream for μ_b, as given in Table A.30.

> In Equation (E-3), the exponent ε_b and the mantissa μ_b are specified in the QCD or QCC marker segments (see A.6.4 and A.6.5), and the nominal dynamic range R_b (as given by Equation (E-4)) is the sum of R_I (the number of bits used to represent the original tile-component samples which can be extracted from the SIZ marker – see Table A.11 in A.5.1) and the base 2 exponent of the sub-band gain (gain_b) of the current sub-band b, which varies with the type of sub-band b (levLL, levLH or levHL, levHH – see F.3.1) and can be found in Table E.1.

**Table E.1 – Sub-band gains**

| sub-band b | gain_b | log₂(gain_b) |
|---|---:|---:|
| levLL | 1 | 0 |
| levLH | 2 | 1 |
| levHL | 2 | 1 |
| levHH | 4 | 2 |

\[
R_b=R_I+\log_2(gain_b)
\qquad\text{(E-4)}
\]

*Editorial omission notice: the remainder of E.1.1.1 and E.1.1.2 is not reproduced here. E.1.2 follows below. Equation E-4 defines R_b; its left-hand side is not ε_b.*

## 3. E.1.2 Reversible transformation (source transcription)

Printed page 108; PDF page 116.

> E.1.2 Reversible transformation
>
> E.1.2.1 Determination of the quantization step size

> For reversible transformation, the quantization step size Δ_b is equal to one (no quantization is performed).

> E.1.2.2 Reconstruction of the transform coefficient

> For reversible transformation, the reconstructed transform coefficient Rq_b(u, v) is recovered differently depending on whether all the coefficient bits are decoded, i.e., whether N_b(u, v) = M_b or N_b(u, v) < M_b.

> If N_b(u, v) = M_b, then the reconstructed transform coefficient Rq_b(u, v) is given by Equation (E-7).

\[
Rq_b(u,v)=\overline{q}_b(u,v)
\qquad\text{(E-7)}
\]

> If N_b(u, v) < M_b, then the reconstructed transform coefficient Rq_b(u, v) is given by Equation (E-8).

\[
Rq_b(u,v)=
\begin{cases}
\left\lfloor\left(\overline{q}_b(u,v)+r2^{M_b-N_b(u,v)}\right)\cdot\Delta_b\right\rfloor
&\text{for }\overline{q}_b(u,v)>0,\\
\left\lceil\left(\overline{q}_b(u,v)-r2^{M_b-N_b(u,v)}\right)\cdot\Delta_b\right\rceil
&\text{for }\overline{q}_b(u,v)<0,\\
0&\text{for }\overline{q}_b(u,v)=0.
\end{cases}
\qquad\text{(E-8)}
\]

*Editorial clarification: the positive branch has floor brackets; the negative branch has ceiling brackets. Both were checked visually. The definition of r immediately above E.1.2, after E-6, reads:*

> where r is a reconstruction parameter, which can be arbitrarily chosen by the decoder.

> NOTE – The reconstruction parameter r may be chosen for example to produce the best visual or objective quality for reconstruction. Generally, values for r fall in the range of 0 ≤ r < 1, and a common value is r = 1/2. (This note also applies to E.1.2).

## 4. E.2 and the encoder exponent equation (source transcription)

Printed pages 108–109; PDF pages 116–117. The word **informative** is part of the source heading.

> E.2 Scalar coefficient quantization (informative)

> For irreversible compression, after the irreversible forward discrete wavelet transformation (see Annex F), each of the transform coefficients a_b(u, v) of the sub-band is quantized to the value q_b(u, v) according to Equation (E-9).

\[
q_b(u,v)=sign(a_b(u,v))\cdot\left\lfloor\frac{|a_b(u,v)|}{\Delta_b}\right\rfloor
\qquad\text{(E-9)}
\]

> where Δ_b is the quantization step size. The exponent ε_b and mantissa corresponding to Δ_b can be derived from Equation (E-5), and must be recorded in the codestream in the QCD or QCC markers (see A.6.4 and A.6.5).

> For reversible compression, the quantization step size is required to be 1. In this case, a parameter ε_b has to be recorded in the codestream in the QCD or QCC markers (see A.6.4 and A.6.5), and is calculated as:

\[
\varepsilon_b=R_I+\log_2(gain_b)+\zeta_c
\qquad\text{(E-10)}
\]

> where R_I and gain_b are as described in E.1.1, and where ζ_c is zero if the RCT is not used and ζ_c is the number of additional bits added by the RCT if the RCT is used, as described in G.2.1.

> For both reversible and irreversible compression, in order to prevent possible overflow or excursion beyond the nominal range of the integer representation of |q_b(u, v)| arising, for example during floating point calculations, the number M_b of bits for the integer representation of q_b(u, v) used at the encoder side is defined by Equation (E-2). The number G of guard bits has to be specified in the QCD or QCC marker (see A.6.4 and A.6.5). Typical values for the number of guard bits are G = 1 or G = 2.

## 5. A.6.4 QCD scope and precedence (source transcription)

Printed page 28; PDF page 36. Selected opening paragraphs:

> A.6.4 Quantization default (QCD)

> Function: Describes the quantization default used for compressing all components not defined by a QCC marker segment. The parameter values can be overridden for an individual component by a QCC marker segment in either the main or tile-part header.

> Usage: Main and first tile-part header of a given tile. It shall be one and only one in the main header. At most, it may be one for all tile-part headers of a tile. If there are multiple tile-parts for a tile, and this marker segment is present, it shall be found only in the first tile-part (TPsot = 0).

> When used in the tile-part header it overrides the main QCD and the main QCC for the specific component. Thus, the order of precedence is the following:

> Tile-part QCC > Tile-part QCD > Main QCC > Main QCD

> where the "greater than" sign > means that the greater overrides the lesser marker segment.

*Editorial omission notice: the length field, Figure A.13, Equation A-4 and its following note are omitted. The parameter descriptions below resume on printed page 29, followed by Tables A.28–A.30; Table A.27 is omitted.*

> Sqcd: Quantization style for all components.

> SPqcd_i: Quantization step size value for the ith sub-band in the defined order (see F.3.1). The number of parameters is the same as the number of sub-bands in the tile-component with the greatest number of decomposition levels.

## 6. Tables A.28–A.30 (source transcription)

Printed page 29; PDF page 37. Bit patterns are shown MSB to LSB.

**Table A.28 – Quantization default values for the Sqcd and Sqcc parameters**

| Value (bits), MSB → LSB | Quantization style | SPqcd or SPqcc size (bits) | SPqcd or SPqcc usage |
|---|---|---:|---|
| `xxx0 0000` | No quantization | 8 | Table A.29 |
| `xxx0 0001` | Scalar derived (values signalled for \({N_L}LL\) sub-band only). Use Equation (E-5) | 16 | Table A.30 |
| `xxx0 0010` | Scalar expounded (values signalled for each sub-band). There are as many step sizes signalled as there are sub-bands | 16 | Table A.30 |
| `000x xxxx` to `111x xxxx` | Number of guard bits: 0 to 7 | | |
| All other values reserved | | | |

**Table A.29 – Reversible step size values for the SPqcd and SPqcc parameters (reversible transform only)**

| Value (bits), MSB → LSB | Reversible step size values |
|---|---|
| `0000 0xxx` to `1111 1xxx` | Exponent, ε_b, of the reversible dynamic range signalled for each sub-band (see Equation (E-5)) |
| All other values reserved | |

**Table A.30 – Quantization values for the SPqcd and SPqcc parameters (irreversible transformation only)**

| Value (bits), MSB → LSB | Quantization step size values |
|---|---|
| `xxxx x000 0000 0000` to `xxxx x111 1111 1111` | Mantissa, μ_b, of the quantization step size value (see Equation (E-3)) |
| `0000 0xxx xxxx xxxx` to `1111 1xxx xxxx xxxx` | Exponent, ε_b, of the quantization step size value (see Equation (E-3)) |

*Editorial observation: A.29 really prints “Equation (E-5)”. In this edition E-5 is the irreversible derived-quantization exponent/mantissa equation. The cross-reference appears inconsistent; it has deliberately not been silently replaced with E-10.*

## 7. Table A.11: component precision and R_I (source transcription)

Printed page 23; PDF page 31. This table belongs to A.5.1.

**Table A.11 – Component Ssiz parameter**

| Value (bits), MSB → LSB | Component sample precision |
|---|---|
| `x000 0000` to `x010 0101` | Component sample bit depth = value + 1. From 1 bit deep to 38 bits deep respectively (counting the sign bit, if appropriate)ᵃ), R_I |
| `0xxx xxxx` | Component sample values are unsigned values |
| `1xxx xxxx` | Component sample values are signed values |
| All other values reserved | |

> a) The component sample precision is limited by the number of guard bits, quantization, growth of coefficients at each decomposition level and the number of coding passes that can be signalled. Not all combinations of coding styles will allow the coding of 38-bit samples.

## 8. Interpretation for the implementing LLM (editorial; not source text)

The inspected clauses do **not** provide the proposed simple normative rule “the encoder shall set ε_b = R_I + log₂(gain_b)”. There are three separate facts:

1. **E-4 defines R_b**, not ε_b.
2. **E-10 supplies an encoder formula for ε_b**, includes **ζ_c**, and is located in the explicitly **informative E.2**. Its language is stronger than a casual description, but its informative placement matters; matching the word “shall” alone is not a sufficient way to classify a requirement.
3. **A.29 describes the signaled reversible dynamic-range exponent**, but does not itself print the proposed equality. Its E-5 cross-reference is problematic in this edition.

Accordingly, these extracts alone do not justify promoting an exponent/precision mismatch to a proven codestream-conformance FAIL. Retain it as a WARN candidate until a separate applicable normative requirement, correction, or authoritative clarification establishes the needed equality. This conclusion does not prove every mismatching stream is conforming.

For any candidate comparison, resolve effective quantization parameters per tile/component using the quoted precedence; decode `R_I = (Ssiz & 0x7f) + 1`; extract the reversible exponent from the upper five bits; and account for RCT before comparing against the informative formula. Neither treating signedness as an extra bit beyond R_I nor ignoring ζ_c is justified by these extracts.

The seven `p0_13` survivors were not supplied or tested in this task. No code, classification, or corpus result was changed.
