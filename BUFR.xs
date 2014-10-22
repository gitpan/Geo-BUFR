/* Copyright (C) 2010 met.no */
/* This module is free software; you can redistribute it and/or */
/* modify it under the same terms as Perl itself. */

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

static unsigned char SetFirstBits[] = {
  0,
  0x80, 0xc0, 0xe0, 0xf0,
  0xf8, 0xfc, 0xfe, 0xff
};
static unsigned char SetLastBits[] = {
  0,
  0x01, 0x03, 0x07, 0x0f,
  0x1f, 0x3f, 0x7f, 0xff
};

MODULE = Geo::BUFR		PACKAGE = Geo::BUFR		

double
bitstream2dec(unsigned char *bitstream,   \
	      int bitpos, int wordlength, \
	      double offset, double scale)

    PROTOTYPE: $$$$$
    CODE:
        /* Extract wordlength bits from bitstream, starting at bitpos. */
        /* The extracted bits are interpreted as a non negative integer, */
        /* then offset is added and the result multiplied with scale. */
        /* Returns undef if all bits extracted are one bits. */

	static unsigned int bitmask[] = {
	    0,
	    0x00000001, 0x00000003, 0x00000007, 0x0000000f,
	    0x0000001f, 0x0000003f, 0x0000007f, 0x000000ff,
	    0x000001ff, 0x000003ff, 0x000007ff, 0x00000fff,
	    0x00001fff, 0x00003fff, 0x00007fff, 0x0000ffff,
	    0x0001ffff, 0x0003ffff, 0x0007ffff, 0x000fffff,
	    0x001fffff, 0x003fffff, 0x007fffff, 0x00ffffff,
	    0x01ffffff, 0x03ffffff, 0x07ffffff, 0x0fffffff,
	    0x1fffffff, 0x3fffffff, 0x7fffffff, 0xffffffff
	};
	int bits = 0;
	int octet = bitpos/8;    /* Which octet the word starts in              */
	int startbit = bitpos & 0x07; /* Offset from start of octet to start of word */
	int lastbits;
	unsigned long word = 0;

	if (wordlength == 0) {
	    word = 0;
	} else if (wordlength > 32) {
	    /* For now, we restrict ourselves to 32-bit words */
	    XSRETURN_UNDEF;
	} else {
	    if (wordlength+startbit <= 8) {
		/* Word to be extracted is within a single octet */
		word = bitstream[octet] >> (8-wordlength-startbit);
		word &= bitmask[wordlength];
	    } else {
		/* Extract bits in first octet */
		bits = 8-startbit;
		word = bitstream[octet++] & bitmask[bits];
		/* Extract complete octets */
		while (wordlength-bits >= 8) {
		    word = (word << 8) | bitstream[octet++];
		    bits += 8;
		}
		/* Extract remaining bits */
		lastbits = wordlength-bits;
		if (lastbits > 0) {
		    word <<= lastbits;
		    word |= (bitstream[octet] >> (8-lastbits)) & bitmask[lastbits];
		}
	    }
	    /* If word contains all ones, it is undefined */
	    if (word == bitmask[wordlength]) {
		XSRETURN_UNDEF;
	    }
	}

	/* Scale return value according to BUFR B table */
	RETVAL = (word+offset)*scale;

    OUTPUT:
	RETVAL


SV *
bitstream2ascii(unsigned char *bitstream, int bitpos, int len)

    PROTOTYPE: $$$
    CODE:
        /* Extract len bytes from bitstream, starting at bitpos, and */
        /* interpret the extracted bytes as an ascii string. Return */
        /* undef if the extracted bytes are all one bits */

        unsigned char str[len+1];
	int octet;
	int lshift;
	int rshift;
        int missing;
        int i;
	SV *ascii;

	octet = bitpos/8;
	lshift = bitpos & 0x07;

	if (lshift == 0) {
	    for (i = 0; i < len; i++)
		str[i] = bitstream[octet+i];
	} else {
	    rshift = 8-lshift;
	    for (i = 0; i < len; i++) {
		str[i] = (bitstream[octet+i  ] << lshift) |
		         (bitstream[octet+i+1] >> rshift);
	    }
	}
	str[len] = '\0';

        /* Check for missing value, i.e, all bits are ones */
        missing = 1;
        for (i = 0; i < len; i++) {
            if (str[i] != 0xff) {
                missing = 0;
            }
        }
        if (missing == 1) {
            XSRETURN_UNDEF;
        }

	ascii = newSVpv(str, len);
	RETVAL = ascii;

    OUTPUT:
	RETVAL


void
dec2bitstream(unsigned long word, \
	      unsigned char *bitstream, \
	      int bitpos, int wordlength)

    PROTOTYPE: $$$$
    CODE:
        /* Encode non negative integer value word in width bits in bitstream, */
        /* starting at bit bitpos. Last byte will be padded with 1 bits */

          int octet = bitpos/8;    /* Which octet the word should start in */
          int startbit = bitpos & 0x07; /* Offset from start of octet to start of word */
          int num_onebits;
          int bits = 0;

          if (wordlength > 0) {
            if (wordlength > 32) {
              /* For now, we restrict ourselves to 32-bit words.
                 Note that 'long' in C is assured to be 4 bytes */
              exit(1);
            } else {
              /* First set the bits after startbit to 0 in first byte of bitstream */
              bitstream[octet] &= SetFirstBits[startbit];
              /* Shift the part of word we want to encode (the last wordlength bits)
        	 so that it starts at startbit in first byte (will be preceded by 0 bits) */
              if (wordlength+startbit < 32) {
                 word <<= (32-wordlength-startbit);
              } else {
                 word >>= (wordlength+startbit-32);
              }
              /* Then extract first byte, which must be shifted to last byte
        	 before doing bitwise OR with an unsigned char */
              bitstream[octet] |= word >> 24;
              /* Then encode remaining bytes in word, if any */
              bits = 8 - startbit;
              while (wordlength-bits > 0) {
        	word <<= 8;
        	bitstream[++octet] = word >> 24;
        	bits += 8;
              }
              /* Finally pad last encoded byte in bitstream with one bits */
              num_onebits = 8 - (startbit + wordlength) & 0x07;
              bitstream[octet] |= SetLastBits[num_onebits];
            }
          }


void
ascii2bitstream(unsigned char *ascii, \
	      unsigned char *bitstream, \
	      int bitpos, int width)

    PROTOTYPE: $$$$
    CODE:
        /* Encode ASCII string ascii in width bytes in bitstream, starting at */
        /* bit bitpos. Last byte will be padded with 1 bits */

        int octet = bitpos/8;    /* Which octet the word should start in */
        int startbit = bitpos & 0x07; /* Offset from start of octet to start of word */
        int lshift;
        int i;

        if (width > 0) {
          if (startbit == 0) {
            /* The easy case: just copy byte for byte */
            for (i = 0; i < width; i++)
              bitstream[octet+i] = ascii[i];
          } else {
            lshift = 8-startbit;
            /* First byte should be first startbit bits of first bitstream byte,
               then first 8-startbit bits of first byte of ascii byte */
            bitstream[octet] = (bitstream[octet] & SetFirstBits[startbit]) |
              (ascii[0] >> startbit);
            /* Next bytes should be last startbit bits of previous ascii byte,
               then first 8-startbit bits of next ascii byte */
            for (i = 1; i < width; i++)
                bitstream[octet+i] = (ascii[i-1] << lshift) | (ascii[i] >> startbit);
            /* Last byte should be remaining startbit bits of last ascii byte,
               padded with 8-startbit one bits */
            bitstream[octet+width] = (ascii[width-1] << lshift) | SetLastBits[8-startbit];
          }
        }


void
null2bitstream(unsigned char *bitstream, \
	      int bitpos, int wordlength)

    PROTOTYPE: $$$$
    CODE:
        /* Set wordlength bits in bitstream starting at bit bitpos to 0 */
        /* bits. Last byte will be padded with 1 bits */

        int octet = bitpos/8;    /* Which octet the word should start in */
        int startbit = bitpos & 0x07; /* Offset from start of octet to start of word */
        int num_onebits;
        int bits;

        if (wordlength > 0) {
          /* First set the bits after startbit to 0 in first byte of bitstream */
          bitstream[octet] &= SetFirstBits[startbit];
          bits = 8 - startbit;
          while (wordlength-bits > 0) {
            bitstream[++octet] = 0x00;
            bits += 8;
          }
          /* Finally pad last encoded byte in bitstream with one bits */
          num_onebits = 8 - (startbit + wordlength) & 0x07;
          bitstream[octet] |= SetLastBits[num_onebits];
        }
