# T.800 (11/2015): jp2h box order, multiple component transformation inputs and marker placement extracts

## Provenance and transcription conventions (editorial)

Source: `T-REC-T.800-201511-S!!PDF-E.pdf`, the same document as
`T800_CODEWORD_SEGMENT_TERMINATION_VERBATIM.md` (SHA-256
`B1CA01EECD3FE13AD58EA2E253C19274EB091E4A3E240B489941C664E96869E0`,
231 PDF pages, ITU-T T.800 (11/2015) common text with
ISO/IEC 15444-1:2016 (E)). Text was extracted with `pdftotext -layout`
on 2026-10-11 and these clauses were read on 2026-10-14. Figures are
transcribed as the text labels the extractor kept.

Prose in blockquotes is verbatim. Line wrapping and column spacing are
normalized. Editorial headings and the interpretation at the end are not
source text. PDF page = printed page + 8.

| Material | Clause | Printed page |
|---|---|---:|
| Construction of first and non-first tile-part headers | A.3, Figures A.4 and A.5 | 18 |
| COD usage | A.6.1 | 23 |
| Multiple component transformation values | Table A.17 | 25 |
| COC usage | A.6.2 | 26 |
| RGN usage | A.6.3 | 27 |
| QCD usage | A.6.4 | 28 |
| QCC usage | A.6.5 | 29 |
| POC usage | A.6.6 | 30 |
| Reversible multiple component transformation | G.2 | 132 |
| Irreversible multiple component transformation | G.3 | 132 |
| Using multiple colourspace methods | I.3.3 | 141 |
| JP2 Header box and its sub-box order | I.5.3, Figure I.7 | 145-146 |
| Image Header box placement | I.5.3.1 | 146 |

## A.3 Construction of the codestream, Figures A.4 and A.5 (printed page 18)

> Figure A.4 – Construction of the first tile-part header of a given tile
> SOT Required as the first marker segment of every tile-part header
> Tile-part header (not first in tile)
> POC Required if any progression order changes different from main POC
> PPT Optional; either PPM or PPT or codestream packet headers required
> PLT Optional
> COM Optional
> SOD Required as the last marker of every tile-part header
> T.800_FA-5
> Figure A.5 – Construction of a non-first tile-part header

## A.6.1 Coding style default (COD), Usage (printed page 23)

> Usage: Main and first tile-part header of a given tile. It shall be one and only one in the main header. Additionally, there
> may be at most one for each tile. If there are multiple tile-parts in a tile and this marker segment is present, it shall be
> found only in the first tile-part (TPsot = 0).

## Table A.17 Multiple component transformation for the SGcod parameters (printed page 25)

> Table A.17 – Multiple component transformation for the SGcod parameters
> Value (bits)
> Multiple component transformation type
> MSB LSB
> 0000 0000 No multiple component transformation specified
> 0000 0001 Component transformation used on components 0, 1, 2 for coding efficiency (see G.2). Irreversible
> component transformation used with the 9-7 irreversible filter. Reversible component transformation
> used with the 5-3 reversible filter.

## A.6.2 Coding style component (COC), Usage (printed page 26)

> Usage: Main and first tile-part header of a given tile. Optional in both the main and tile-part headers. No more than one
> per any given component may be present in either the main or tile-part headers. If there are multiple tile-parts in a tile,
> and this marker segment is present, it shall be found only in the first tile-part (TPsot = 0).

## A.6.3 Region of interest (RGN), Usage (printed page 27)

> Usage: Main and first tile-part header of a given tile. If used in the main header, it refers to the ROI scaling value for one
> component in the whole image, valid for all tiles except those with an RGN marker segment.
> When used in the tile-part header, the scaling value is valid only for one component in that tile. There may be at most one
> RGN marker segment for each component in either the main or tile-part headers. The RGN marker segment for a particular

## A.6.4 Quantization default (QCD), Usage (printed page 28)

> Usage: Main and first tile-part header of a given tile. It shall be one and only one in the main header. At most, it may be
> one for all tile-part headers of a tile. If there are multiple tile-parts for a tile, and this marker segment is present, it shall
> be found only in the first tile-part (TPsot = 0).

## A.6.5 Quantization component (QCC), Usage (printed page 29)

> Usage: Main and first tile-part header of a given tile. Optional in both the main and tile-part headers. No more than one
> per any given component may be present in either the main or tile-part headers. If there are multiple tile-parts in a tile,
> and this marker segment is present, it shall be found only in the first tile-part (TPsot = 0).

## A.6.6 Progression order change (POC), Usage (printed page 30)

> Usage: Main and tile-part headers. At most one POC marker segment may appear in any header. However, several
> progressions can be described with one POC marker segment. If a POC marker segment is used in the main header, it
> overrides the progression order in the main and tile COD marker segments. If a POC is used to describe the progression
> of a particular tile, a POC marker segment must appear in the first tile-part header of that tile. Thus, the progression order
> of a given tile is determined by the presence of the POC or the values of the COD in the following order of precedence:

## G.2 Reversible multiple component transformation (RCT), opening (printed page 132)

> G.2 Reversible multiple component transformation (RCT)
> The use of the reversible multiple component transformation is signalled in the COD marker segment (see A.6.1). The
> RCT shall be used only with the 5-3 reversible filter. The RCT is a decorrelating transformation applied to the first three
> components of an image (indexed as 0, 1 and 2). The three components input into the RCT shall have the same separation
> on the reference grid and the same bit-depth.
> NOTE – While the RCT is reversible, and thus capable of lossless compression, it may be used in truncated codestreams to provide

## G.3 Irreversible multiple component transformation (ICT), opening (printed page 132)

> After applying the Inverse RCT, the unsigned image components are inverse DC level shifted.
> G.3 Irreversible multiple component transformation (ICT)
> This clause specifies an irreversible multiple component transformation. The use of the irreversible component
> transformation is signalled in the COD marker segment (see A.6.1). The ICT shall be used only with the 9-7 irreversible
> filter. The ICT is a decorrelating transformation applied to the first three components of an image (indexed as 0, 1 and 2).

## I.3.3 Using multiple methods (printed page 141)

> I.3.3 Using multiple methods
> Architecturally, the format allows for multiple methods to be embedded in a file and allows other standards to define
> additional enumerated methods and to define extended methods. This provides readers conforming to these extensions a
> choice as to what image processing path should be used to interpret the colourspace of the image. However, the first
> method found in the file (in the first Colourspace Specification box in the JP2 Header box) shall be one of the methods
> as defined and restricted in this Recommendation | International Standard. A conforming reader shall use that first method
> and ignore all other methods (in additional Colourspace Specification boxes) found in the file.

## I.5.3 JP2 Header box (superbox), with Figure I.7 (printed pages 145-146)

> I.5.3 JP2 Header box (superbox)
> The JP2 Header box contains generic information about the file, such as the number of components, colourspace and grid
> resolution. This box is a superbox. Within a JP2 file, there shall be one and only one JP2 Header box. The JP2 Header
> box may be located anywhere within the file after the File Type box but before the Contiguous Codestream box. It also
> must be at the same level as the JPEG 2000 Signature and File Type boxes (it shall not be inside any other superbox
> within the file).
> The type of the JP2 Header box shall be 'jp2h' (0x6A70 3268).
> This box contains several boxes. Other boxes may be defined in other standards and may be ignored by conforming
> readers. Those boxes contained within the JP2 Header box that are defined within this Recommendation | International
> Standard are as in Figure I.7:
> ihdr bpcc colr0 colrn–1 pclr cmap cdef res
> T.800_FI-7
> Figure I.7 – Organization of the contents of a JP2 Header box
> ihdr: Image Header box. This box specifies information about the reference grid geometry, bit depth and
> the number of components. This box shall be the first box in the JP2 Header box.
> bpcc: Bits Per Component box. This box specifies the bit depth of each component in the codestream after
> decompression. Its structure is specified in I.5.3.2. This box may be found anywhere in the JP2 Header
> box provided that it comes after the Image Header box.
> colri: Colour Specification boxes. These boxes specify the colourspace of the decompressed image. Their
> structures are specified in I.5.3.3. There shall be at least one Colour Specification box within the JP2
> Header box. The use of multiple Colour Specification boxes provides the ability for a decoder to be
> given multiple optimization or compatibility options for colour processing. These boxes may be found
> anywhere in the JP2 Header box provided that they come after the Image Header box. All Colour
> Specification boxes shall be contiguous within the JP2 Header box.
> pclr: Palette box. This box defines the palette to be used to create multiple components from a single
> component. Its structure is specified in I.5.3.4. This box may be found anywhere in the JP2 Header
> box provided that it comes after the Image Header box.
> cmap: Component Mapping box. This box defines how image channels are identified from the actual
> components in the codestream. Its structure is specified in I.5.3.5. This box may be found anywhere
> in the JP2 Header box provided that it comes after the Image Header box.
> cdef: Channel Definition box. This box defines the channels in the image. Its structure is specified in I.5.3.6.
> This box may be found anywhere in the JP2 Header box provided that it comes after the Image Header
> box.
> res: Resolution box. This box specifies the capture and default display grid resolutions of the image. Its
> structure is specified in I.5.3.7. This box may be found anywhere in the JP2 Header box provided that
> it comes after the Image Header box.

## I.5.3.1 Image Header box, opening (printed page 146)

> I.5.3.1 Image Header box
> This box contains fixed length generic information about the image, such as the image size and number of components.
> The contents of the JP2 Header box shall start with an Image Header box. Instances of this box in other places in the file
> shall be ignored. The length of the Image Header box shall be 22 bytes, including the box length and type fields. Much
> of the information within the Image Header box is redundant with information stored in the codestream itself.
> All references to "the codestream" in the descriptions of fields in this Image Header box apply to the codestream found
> in the first Contiguous Codestream box in the file. Files that contain contradictory information between the Image Header
> box and the first codestream are not conforming files. However, readers may choose to attempt to read these files by using

## Interpretation (editorial, not source text)

- jp2h order (I.5.3, I.5.3.1): "This box shall be the first box in the JP2
  Header box" and "The contents of the JP2 Header box shall start with an
  Image Header box." A jp2h whose first sub-box is not ihdr is a proven
  violation. Every other defined sub-box "may be found anywhere in the JP2
  Header box provided that it comes after the Image Header box", which the
  same check covers.
- colr presence and grouping (I.5.3): "There shall be at least one Colour
  Specification box within the JP2 Header box" and "All Colour Specification
  boxes shall be contiguous within the JP2 Header box." A jp2h without a colr
  box, or with colr boxes separated by another box, is a proven violation.
- first colr method (I.3.3): "the first method found in the file (in the
  first Colourspace Specification box in the JP2 Header box) shall be one of
  the methods as defined and restricted in this Recommendation | International
  Standard." The methods Part 1 defines are METH 1 (enumerated) and METH 2
  (restricted ICC). A first colr box with another METH is a proven violation;
  later colr boxes are ignored by a conforming reader and get structural
  checks only.
- Multiple component transformation (Table A.17, G.2, G.3): SGcod MCT value 1
  is "Component transformation used on components 0, 1, 2", and both G.2 and
  G.3 say "The three components input into the RCT shall have the same
  separation on the reference grid and the same bit-depth" (ICT: the same
  sentence). MCT 1 with fewer than three components has no defined meaning
  (undecodable, so FAIL under the 2026-09-06 severity policy); MCT 1 with
  components 0, 1, 2 differing in XRsiz, YRsiz or Ssiz is a proven violation.
- Tile-part header placement (A.6.1, A.6.2, A.6.4, A.6.5): COD, COC, QCD and
  QCC each say "If there are multiple tile-parts in a tile, and this marker
  segment is present, it shall be found only in the first tile-part
  (TPsot = 0)." RGN (A.6.3) is defined for "Main and first tile-part header
  of a given tile" and Figure A.5 lists only POC, PPT, PLT, COM and SOD for a
  non-first tile-part header. Any of the five in a tile-part header with
  TPsot > 0 is a proven violation. POC (A.6.6) is allowed in any tile-part
  header, but "If a POC is used to describe the progression of a particular
  tile, a POC marker segment must appear in the first tile-part header of
  that tile", so a tile whose first POC arrives in a later tile-part is also
  a proven violation.
