# T.800 (11/2015): codeword segment length and coder termination extracts

## Provenance and transcription conventions (editorial)

Source: `T-REC-T.800-201511-S!!PDF-E.pdf`, the same document as
`T800_REVERSIBLE_QUANTIZATION_VERBATIM.md` (SHA-256
`B1CA01EECD3FE13AD58EA2E253C19274EB091E4A3E240B489941C664E96869E0`,
231 PDF pages, ITU-T T.800 (11/2015) common text with
ISO/IEC 15444-1:2016 (E)). Text was extracted with `pdftotext -layout`
on 2026-10-11. Flowcharts are described, not transcribed.

Prose in blockquotes is verbatim. Line wrapping is normalized. Editorial
headings and the interpretation at the end are not source text.

| Material | Clause | Printed page | PDF page |
|---|---|---:|---:|
| Code-block contribution length | B.10.7, B.10.7.1, B.10.7.2 | 69 | 77 |
| FLUSH, final byte discard | C.2.9 (end) | 87 | 95 |
| BYTEIN marker synthesis | C.3.4 | 94 | 102 |
| Termination patterns | D.4, Table D.8 | 102 | 110 |
| Decoder-side extension with 0xFF | D.4.1 | 102 | 110 |
| Encoder-side termination, PTERM | D.4.2 | 102-103 | 110-111 |
| Length computation | D.4.3 (informative) | 103 | 111 |
| Raw (bypass) segment termination | D.6 | 103-104 | 111-112 |

## 1. B.10.7 Length of the compressed image data from a given code-block

> The packet header identifies the number of bytes contributed by each
> included code-block. The sequence of bytes actually included for any
> given code-block must not end in a 0xFF. Thus, in the event that an 0xFF
> appears at the end of a code-block's contribution to a packet, the 0xFF
> may be safely moved to the subsequent packet which contains
> contributions from the code-block, or dropped if there is no such
> packet. The example coding pass length calculation algorithm described
> in Annex D ensures that no coding pass will ever be considered as ending
> with an 0xFF.
>
> NOTE – This is, in fact, not a burdensome requirement, since 0xFFs are
> always synthesized as necessary by the arithmetic coder described in
> Annex C.
>
> In signalling the number of bytes contributed by the code-block, there
> are two cases: the code-block contribution contains a single codeword
> segment; or the code-block contribution contains multiple codeword
> segments. Multiple codeword segments arise when a termination occurs
> between coding passes which are included in the packet, as shown in
> Tables D.8 and D.9.

### B.10.7.1 Single codeword segment

> A codeword segment is the number of bytes contributed to a packet by a
> code-block. The length of a codeword segment is represented by a binary
> number of length:
>
> bits = Lblock + floor(log2(coding passes added)) (B-19)
>
> where Lblock is a code-block state variable. A separate Lblock is used
> for each code-block in the precinct. The value of Lblock is initially
> set to three. The number of bytes contributed by each code-block is
> preceded by signalling bits that increase the value of Lblock, as
> needed. A signalling bit of zero indicates the current value of Lblock
> is sufficient. If there are k ones followed by a zero, the value of
> Lblock is incremented by k. While Lblock can only increase, the number
> of bits used to signal the length of the code-block contribution can
> increase or decrease depending on the number of coding passes included.
>
> NOTE 2 – There is no requirement that the minimum number of bits be used
> to signal length (any number is valid).

(NOTE 1, a worked example of the comma code, is omitted.)

### B.10.7.2 Multiple codeword segments

> Let T be the set of indices of terminated coding passes included for the
> code-block in the packet as indicated in Tables D.8 and D.9. If the
> index final coding pass included in the packet is not a member of T,
> then it is added to T. Let n1 < ... < nK be the indices in T. K lengths
> are signalled consecutively with each length using the mechanism
> described in B.10.7.1. The first length is the number of bytes from the
> start of the code-block's contribution in this packet to the end of
> coding pass n1. The number of added coding passes for the purposes of
> Equation (B-19) is the number of passes in the packet up through n1. The
> second length is the number of bytes from the end of coding pass, n1, to
> the end of coding pass, n2. The number of added coding passes for the
> purposes of Equation (B-19) is n2 – n1. This procedure is repeated for
> all K lengths.

(The NOTE with the bypass worked example is omitted.)

## 2. C.2.9 FLUSH (closing paragraph)

> The byte in the C-register is then completed by shifting C, and two
> bytes are then removed. If the byte in buffer B is an 0xFF then it is
> discarded. Otherwise, buffer B is output to the bit stream.
>
> NOTE – This is the only normative option for termination in Rec. ITU-T
> T.88 | ISO/IEC 14492. However, further reduction of the bit stream is
> allowed in this Recommendation | International Standard provided correct
> decoding is assured (see D.4.2).

## 3. C.3.4 Compressed image data input (BYTEIN)

> The BYTEIN procedure called from RENORMD is illustrated in Figure C.19.
> This procedure reads in one byte of data, compensating for any stuff
> bits following the 0xFF byte in the process. It also detects the marker
> codes which must occur at the end of a coding pass. The C-register in
> this procedure is the concatenation of the Chigh and Clow registers.

Figure C.19 (described, not transcribed): if the byte at BP is 0xFF and
the next byte B1 is greater than 0x8F, BP does not advance; 0xFF00 is
added to C and CT = 8 (a marker, or the synthesized end of data, feeds
ones forever). If B is 0xFF and B1 is not greater than 0x8F, BP advances,
C gets B shifted by 9 and CT = 7 (bit stuffing). Otherwise BP advances,
C gets B shifted by 8 and CT = 8.

## 4. D.4 Initializing and terminating

> In normal operation (not selective arithmetic coding bypass), the
> arithmetic coder shall be terminated either at the end of every coding
> pass or only at the end of every code-block (see D.4.1). Table D.8 shows
> two examples of termination patterns for the coding passes in a
> code-block. The COD or COC marker signals which termination pattern is
> used (see A.6.1 and A.6.2).
>
> When multiple terminations of the arithmetic coder are present, the
> length of each terminated segment is signalled in the packet header as
> described in B.10.7.
>
> NOTE – Termination should never create a byte aligned value between
> 0xFF90 and 0xFFFF inclusive. These values are available as
> in-bit-stream marker values.

### D.4.1 Expected codestream termination

> The decoder anticipates that the given number of codestream bytes will
> decode a given number of coding passes before the arithmetic coder is
> terminated. During decoding, bytes are pulled successively from the
> codestream until all the bytes for those coding passes have been
> consumed. The number of bytes corresponding to the coding passes is
> specified in the packet header. Often at that point there are more
> symbols to be decoded. Therefore, the decoder shall extend the input bit
> stream to the arithmetic coder with 0xFF bytes, as necessary, until all
> symbols have been decoded.
>
> It is sufficient to append no more than two 0xFF bytes. This will cause
> the arithmetic coder to have at least one pair of consecutive 0xFF bytes
> at its input which is interpreted as an end-of-stream marker (see
> C.3.4). The bit stream does not actually contain a terminating marker.
> However, the byte length is explicitly signalled enabling the
> terminating marker to be synthesized for the arithmetic decoder.
>
> NOTE – Two 0xFF bytes appended in this way is the simplest method.
> However, other equivalent extensions exist. This might be important
> since some arithmetic coder implementations might attach special meaning
> to the specific termination marker.

### D.4.2 Arithmetic coder termination

> The FLUSH procedure performs this task (see C.2.9). However, since the
> FLUSH procedure increases the length of the codestream, and frequent
> termination may be desirable, other techniques may be employed. Any
> technique that places all of the needed bytes in the codestream in such
> a way that the decoder need not backtrack to find the position at which
> the next segment of the codestream should begin is acceptable.
>
> When the predictable termination flag is set (see COD and COC in A.6.1
> and A.6.2) the following termination procedure shall be used. Using the
> notation of C.2, the followings steps can be used:
>
> 1) Identify the number of bits in code register, C, which must be
> pushed out through the byte buffer. This is given by k = (11 – CT) + 1.
>
> 2) While (k > 0):
> – shift C left by CT and set CT = 0.
> – execute the BYTEOUT procedure. This sets CT equal to the number of
> bits cleared out of the C register.
> – subtract CT from k.
>
> 3) Execute the BYTEOUT procedure to push the contents of the byte
> buffer register out to the codestream. This step shall be skipped if the
> byte in the byte buffer has an 0xFF byte value.
>
> The relevant truncation length in this case is simply the total number
> of bytes pushed out onto the codestream.
>
> If the predictable termination flag is not set, the last byte output by
> the above procedure can generally be modified, within certain bounds,
> without affecting the symbols to be decoded. It will sometimes be
> possible to augment the last byte to the special value, 0xFF, which
> shall not be sent. It can be shown that this happens approximately 1/8
> of the time.

### D.4.3 Length computation (informative)

> To include coding pass compressed image data into packets, the number of
> bytes to be included must be determined. If the coding pass compressed
> image data is terminated, the algorithm in the previous clause may be
> used. Otherwise, the encoder should calculate a suitable length such
> that corresponding bytes are sufficient for the decoder to reconstruct
> the coding passes.

## 5. D.6 Selective arithmetic coding bypass (termination paragraphs)

> The length of each terminated segment, plus the length of any remaining
> unterminated passes, is signalled in the packet header as described in
> B.10.7. If termination on each coding pass is selected (see A.6.1 and
> A.6.2), then every pass is terminated (including both raw passes).
>
> If a 0xFF value is encountered in the bit stream, then the first bit of
> the next byte is discarded. The sequence of bits used in the selective
> arithmetic coding bypass have been stuffed into bytes using a
> bit-stuffing routine.
>
> At the encoder, bits are packed into bytes from the most significant bit
> to the least significant bit. Once a complete byte is assembled, it is
> emitted to the bit stream. If the value of the byte is an 0xFF, a single
> zero bit is stuffed into the most significant bit of the next byte. Once
> all bits of the coding pass have been assembled, the last byte is packed
> to the byte boundary and emitted. The last byte shall not be an 0xFF
> value.
>
> NOTE 2 – Since the decoder appends 0xFF values, as necessary, to the bit
> stream representing the coding pass (see D.4.1), truncation of the bit
> stream may be possible. When the predictable termination flag is set
> (see COD and COC in A.6.1 and A.6.2), such truncation is not permitted.
> The last byte cannot be an 0xFF, since the bit-stuffing routine appends
> a new byte following the FF which has the, most significant bit value
> of 0 and unused bits filled with the alternating sequence of 0 and 1
> value bits.

## 6. Interpretation for the implementing LLM (editorial; not source text)

The question these extracts were pulled for: is a code-block contribution
that carries bytes beyond what the arithmetic decoder consumes (jp2z
finding 252, `entropy_under_read`) a proven nonconformance?

1. **Without predictable termination, no.** D.4.2 makes any termination
   technique acceptable that "places all of the needed bytes in the
   codestream" without forcing the decoder to backtrack for the next
   segment. Surplus bytes satisfy both conditions: the needed bytes are
   present, and the signaled length (B.10.7) fixes where the next segment
   begins. D.4.1 binds only the decoder, and only for the short case
   (extend with 0xFF). D.4.3, the clause that would tell an encoder how
   many bytes to emit, is informative and asks for a length "sufficient",
   not exact. No clause requires the contribution to equal the FLUSH
   output or to be minimal. The 3-byte tails seen in the field (cblksty
   0x00 witnesses in `docs/mktp-research/jpeg2000.md` 4.5) are therefore
   conforming as far as the length goes.
2. **With predictable termination (cblksty bit 0x10), yes.** D.4.2 says
   the listed procedure "shall be used" and that the segment length "is
   simply the total number of bytes pushed out". The output of that
   procedure is deterministic, so any byte beyond it is proven surplus.
   D.6 NOTE 2 says the same for raw segments ("such truncation is not
   permitted", so the raw segment is exact in both directions). This is
   the case OpenJPEG checks (`opj_mqc_check_pterm`), and the only case
   the standard supports checking.
3. **A trailing 0xFF is a violation in every mode.** B.10.7 "must not end
   in a 0xFF" (MQ), D.4.2 "shall not be sent" (MQ, non-PTERM), D.6 "shall
   not be an 0xFF value" (raw). Proven from one byte of the contribution.
   jp2z does not check this today.
4. **Too few bytes remains a violation.** D.4.2's acceptability condition
   requires "all of the needed bytes"; D.4.1 says appending at most two
   0xFF bytes is sufficient for a correctly terminated segment. A decoder
   that must synthesize more than two bytes to finish the signaled passes
   has a segment that omits needed bytes. This supports the existing
   `overReadCap` of 2 for finding 251.
5. **Markers in the tail.** The D.4 NOTE that termination "should never
   create" a value in 0xFF90..0xFFFF is a note with "should"; it cannot
   carry a FAIL. Surplus bytes that form such a value are at most a WARN.

Consequence for jp2z: finding 252 as classified on 2026-10-11 (strict
FAIL on any MQ segment with a tail above 2, regardless of cblksty) is a
false positive for every non-PTERM stream. Code was not changed when this
extract was written; see PLAN.md for the work item.
