/*
 *   Creation Date: <2002/10/23 20:26:40 samuel>
 *   Time-stamp: <2004/01/07 19:39:15 samuel>
 *
 *     <video_common.c>
 *
 *     Shared video routines
 *
 *   Copyright (C) 2002, 2003, 2004 Samuel Rydh (samuel@ibrium.se)
 *
 *   This program is free software; you can redistribute it and/or
 *   modify it under the terms of the GNU General Public License
 *   as published by the Free Software Foundation
 *
 */

#include "config.h"
#include "libc/vsprintf.h"
#include "libopenbios/bindings.h"
#include "libopenbios/fontdata.h"
#include "libopenbios/ofmem.h"
#include "libopenbios/video.h"
#include "packages/video.h"
#include "drivers/vga.h"
#define NO_QEMU_PROTOS
#include "arch/common/fw_cfg.h"

struct video_info video;

#ifdef CONFIG_TACUS
/* The TCX accelerator of the SunSparcStation core (as on a Sun TCX, and in
   QEMU): a 32-bit store into the blit space at (pixel << 3) | 4 copies
   ((v >> 24) & 31) + 1 pixels from pixel v[19:0] there, or fills them with
   the colour stored at offset 0 of the space when v[23:16] is 0xff. The
   core holds the next access to the TCX until the operation is over. The
   stores are physical (MMU bypass): the space's pa[35:32] is the ASI's low
   nibble, 0xe on the SS20 and 0 on the SS5. The scroll and the clears go
   through it; acc_blit is 0 when there is none (CG3). */
static uint32_t acc_blit;
static int acc_asi_e;

static inline void acc_st(uint32_t pa, uint32_t v)
{
	if (acc_asi_e)
		__asm__ __volatile__("sta %0, [%1] 0x2e" : : "r"(v), "r"(pa) : "memory");
	else
		__asm__ __volatile__("sta %0, [%1] 0x20" : : "r"(v), "r"(pa) : "memory");
}

void video_accel_init(uint64_t tcx_base)
{
	acc_asi_e = (tcx_base >> 32) == 0xe;
	acc_blit = (uint32_t)tcx_base + 0x6000000;
}

static int acc_ok(void)
{
	return acc_blit && VIDEO_DICT_VALUE(video.ih) && VIDEO_DICT_VALUE(video.depth) == 8;
}

/* n pixels from pixel p: filled with the colour last stored (src < 0), or
   copied from pixel src, in runs of 32, in increasing order */
static void acc_run(uint32_t p, int src, int n)
{
	while (n > 0) {
		int k = n > 32 ? 32 : n;
		acc_st(acc_blit + (p << 3) + 4,
		       ((uint32_t)(k - 1) << 24) | (src < 0 ? 0xffffff : (uint32_t)src));
		p += k;
		n -= k;
		if (src >= 0)
			src += k;
	}
}
#endif

unsigned long
video_get_color( int col_ind )
{
	unsigned long col;
	if( !VIDEO_DICT_VALUE(video.ih) || col_ind < 0 || col_ind > 255 )
		return 0;
	if( VIDEO_DICT_VALUE(video.depth) == 8 )
		return col_ind;
	col = video.pal[col_ind];
	if( VIDEO_DICT_VALUE(video.depth) == 24 || VIDEO_DICT_VALUE(video.depth) == 32 )
		return col;
	if( VIDEO_DICT_VALUE(video.depth) == 15 )
		return ((col>>9) & 0x7c00) | ((col>>6) & 0x03e0) | ((col>>3) & 0x1f);
	return 0;
}

/* ( fbaddr maskaddr width height fgcolor bgcolor -- ) */

static void
mask_blit(unsigned char *fbaddr, unsigned char *mask, ucell width, ucell height,
	  ucell fgcolor, ucell bgcolor)
{
	ucell color;
	unsigned char *dst, *rowdst;
	int x, y, m, b, d, depthbytes;

	fgcolor = video_get_color(fgcolor);
	bgcolor = video_get_color(bgcolor);
	d = VIDEO_DICT_VALUE(video.depth);
	depthbytes = (d + 1) >> 3;

	dst = fbaddr;
	for( y = 0; y < height; y++) {
		rowdst = dst;
		for( x = 0; x < (width + 1) >> 3; x++ ) {
			for (b = 0; b < 8; b++) {
				m = (1 << (7 - b));

				if (*mask & m) {
					color = fgcolor;
				} else {
					color = bgcolor;
				}

				if( d >= 24 )
					*((uint32_t*)dst) = color;
				else if( d >= 15 )
					*((uint16_t*)dst) = color;
				else
					*dst = color;

				dst += depthbytes;
			}
			mask++;
		}
		dst = rowdst;
		dst += VIDEO_DICT_VALUE(video.rb);
	}
}

void
video_mask_blit(void)
{
	ucell bgcolor = POP();
	ucell fgcolor = POP();
	ucell height = POP();
	ucell width = POP();
	unsigned char *mask = (unsigned char *)POP();
	unsigned char *fbaddr = (unsigned char *)POP();

	mask_blit(fbaddr, mask, width, height, fgcolor, bgcolor);
}

/* ( x y w h fgcolor bgcolor -- ) */

void
video_invert_rect( void )
{
	ucell bgcolor = POP();
	ucell fgcolor = POP();
	int h = POP();
	int w = POP();
	int y = POP();
	int x = POP();
	char *pp;

	bgcolor = video_get_color(bgcolor);
	fgcolor = video_get_color(fgcolor);

	if (!VIDEO_DICT_VALUE(video.ih) || x < 0 || y < 0 || w <= 0 || h <= 0 ||
		x + w > VIDEO_DICT_VALUE(video.w) || y + h > VIDEO_DICT_VALUE(video.h))
		return;

	pp = (char*)VIDEO_DICT_VALUE(video.mvirt) + VIDEO_DICT_VALUE(video.rb) * y;
	for( ; h--; pp += *(video.rb) ) {
		int ww = w;
		if( VIDEO_DICT_VALUE(video.depth) == 24 || VIDEO_DICT_VALUE(video.depth) == 32 ) {
			uint32_t *p = (uint32_t*)pp + x;
			while( ww-- ) {
				if (*p == fgcolor) {
					*p++ = bgcolor;
				} else if (*p == bgcolor) {
					*p++ = fgcolor;
				}
			}
		} else if( VIDEO_DICT_VALUE(video.depth) == 16 || VIDEO_DICT_VALUE(video.depth) == 15 ) {
			uint16_t *p = (uint16_t*)pp + x;
			while( ww-- ) {
				if (*p == (uint16_t)fgcolor) {
					*p++ = bgcolor;
				} else if (*p == (uint16_t)bgcolor) {
					*p++ = fgcolor;
				}
			}
		} else {
			char *p = (char *)(pp + x);

			while( ww-- ) {
				if (*p == (char)fgcolor) {
					*p++ = bgcolor;
				} else if (*p == (char)bgcolor) {
					*p++ = fgcolor;
				}
			}
		}
	}
}

/* ( color_ind x y width height -- ) (?) */
static void
fill_rect(int col_ind, int x, int y, int w, int h)
{
	char *pp;
	unsigned long col = video_get_color(col_ind);

        if (!VIDEO_DICT_VALUE(video.ih) || x < 0 || y < 0 || w <= 0 || h <= 0 ||
            x + w > VIDEO_DICT_VALUE(video.w) || y + h > VIDEO_DICT_VALUE(video.h))
		return;

#ifdef CONFIG_TACUS
	if (acc_ok() && w >= 16) {
		uint32_t p = VIDEO_DICT_VALUE(video.rb) * y + x;

		acc_st(acc_blit, col);
		if (x == 0 && w == (int)VIDEO_DICT_VALUE(video.rb)) {
			acc_run(p, -1, w * h);          /* whole lines: one run */
		} else {
			for (; h--; p += VIDEO_DICT_VALUE(video.rb))
				acc_run(p, -1, w);
		}
		return;
	}
#endif
	pp = (char*)VIDEO_DICT_VALUE(video.mvirt) + VIDEO_DICT_VALUE(video.rb) * y;
	for( ; h--; pp += VIDEO_DICT_VALUE(video.rb) ) {
		int ww = w;
		if( VIDEO_DICT_VALUE(video.depth) == 24 || VIDEO_DICT_VALUE(video.depth) == 32 ) {
			uint32_t *p = (uint32_t*)pp + x;
			while( ww-- )
				*p++ = col;
		} else if( VIDEO_DICT_VALUE(video.depth) == 16 || VIDEO_DICT_VALUE(video.depth) == 15 ) {
			uint16_t *p = (uint16_t*)pp + x;
			while( ww-- )
				*p++ = col;
		} else {
                        char *p = (char *)(pp + x);

			while( ww-- )
				*p++ = col;
		}
	}
}

void
video_fill_rect(void)
{
	int h = POP();
	int w = POP();
	int y = POP();
	int x = POP();
	int col_ind = POP();

	fill_rect(col_ind, x, y, w, h);
}

/* The display's write method for runs of plain text: printable characters,
   CR and LF are handled here; any other character, and every one inside an
   escape sequence, goes to the Forth terminal emulator, (term-emit), which
   keeps the same state (the values below). The Forth emulator costs about
   a millisecond a character on the core; this, a few microseconds. */
static struct {
	volatile ucell *line, *col, *lines, *cols, *inverse, *fg, *bg;
	volatile ucell *cw, *ch, *wtop, *wleft, *esc, *font, *fontbytes;
	volatile ucell *charmin, *charnum, *spacing;
} term;

#define TV(x) (*(ucell *)(term.x))

/* The data address of a value: ['] name cell+, through the C findword()
   (the Forth interpreter's $find walks the dictionary in Forth, some 10 M
   cycles a word on the TACUS CPU, and setup_video() looks up some 40). */
static volatile ucell *value_addr(const char *name)
{
	char buf[64];
	xt_t xt = findword(name);

	if (xt)
		return cell2pointer(xt + sizeof(cell));
	snprintf(buf, sizeof(buf), "['] %s cell+", name);
	feval(buf);
	return cell2pointer(POP());
}

/* to name ( x -- ), for a value or a defer, through findword() too */
static void to_word(const char *name)
{
	char buf[64];
	xt_t xt = findword(name);

	if (xt) {
		PUSH(xt);
		fword("(to-xt)");
		return;
	}
	snprintf(buf, sizeof(buf), "to %s", name);
	feval(buf);
}

static void term_newline(void)
{
	TV(col) = 0;
	TV(line) = TV(line) + 1;
	if (TV(line) >= TV(lines)) {
		TV(line) = 0;
		PUSH(1);
		fword("delete-lines");
		TV(line) = TV(lines) - 1;
	}
}

/* ( addr len -- ) */
static void
video_write(void)
{
	ucell len = POP();
	unsigned char *s = (unsigned char *)POP();

	while (len--) {
		unsigned char c = *s++;

		if (TV(esc) == 0 && c >= 0x20 && c < 0x7f) {
			int x, y, g;
			ucell fg = TV(fg), bg = TV(bg);

			if (TV(col) >= TV(cols))
				term_newline();         /* wrap */
			x = TV(col) * TV(cw) + TV(wleft);
			y = TV(line) * TV(ch) + TV(wtop);
			fill_rect(bg, x, y, TV(cw), TV(ch));
			g = c - (int)TV(charmin);
			if (g > (int)TV(charnum))
				g = TV(charnum);
			if (TV(inverse)) {
				ucell t = fg;
				fg = bg;
				bg = t;
			}
			mask_blit((unsigned char *)VIDEO_DICT_VALUE(video.mvirt) +
				  y * VIDEO_DICT_VALUE(video.rb) + x *
				  ((VIDEO_DICT_VALUE(video.depth) + 1) >> 3),
				  (unsigned char *)TV(font) + g * TV(fontbytes),
				  TV(cw), TV(ch) - TV(spacing), fg, bg);
			TV(col) = TV(col) + 1;
		} else if (TV(esc) == 0 && c == '\r') {
			TV(col) = 0;
		} else if (TV(esc) == 0 && c == '\n') {
			term_newline();
		} else {
			PUSH(c);
			fword("(term-emit)");
		}
	}
}

/* ( src dst len -- ): move for the console's scroll (fb8-copy-lines);
   inside the framebuffer, a downward copy goes through the accelerator */
static void
video_move(void)
{
	ucell len = POP();
	unsigned char *dst = (unsigned char *)POP();
	unsigned char *src = (unsigned char *)POP();

#ifdef CONFIG_TACUS
	unsigned char *fb = (unsigned char *)VIDEO_DICT_VALUE(video.mvirt);
	ucell size = VIDEO_DICT_VALUE(video.rb) * VIDEO_DICT_VALUE(video.h);

	if (acc_ok() && dst < src && dst >= fb && src + len <= fb + size) {
		acc_run(dst - fb, src - fb, len);
		return;
	}
#endif
	memmove(dst, src, len);
}

void setup_video()
{
	/* Make everything inside the video_info structure point to the
	   values in the Forth dictionary. Hence everything is always in
	   sync. */
	char buf[6];

	video.ih = value_addr("display-ih");
	video.mvirt = value_addr("frame-buffer-adr");
	video.w = value_addr("openbios-video-width");
	video.h = value_addr("openbios-video-height");
	video.depth = value_addr("depth-bits");
	video.rb = value_addr("line-bytes");
	video.pal = value_addr("color-palette");

	/* Set global variables ready for fb8-install */
	PUSH( pointer2cell(video_mask_blit) );
	fword("is-noname-cfunc");
	to_word("fb8-blitmask");
	PUSH( pointer2cell(video_fill_rect) );
	fword("is-noname-cfunc");
	to_word("fb8-fillrect");
	PUSH( pointer2cell(video_invert_rect) );
	fword("is-noname-cfunc");
	to_word("fb8-invertrect");
	PUSH( pointer2cell(video_move) );
	fword("is-noname-cfunc");
	to_word("fb8-move");
	PUSH( pointer2cell(video_write) );
	fword("is-noname-cfunc");
	to_word("fb-write");

	term.line = value_addr("line#");
	term.col = value_addr("column#");
	term.lines = value_addr("#lines");
	term.cols = value_addr("#columns");
	term.inverse = value_addr("inverse?");
	term.fg = value_addr("foreground-color");
	term.bg = value_addr("background-color");
	term.cw = value_addr("char-width");
	term.ch = value_addr("char-height");
	term.wtop = value_addr("window-top");
	term.wleft = value_addr("window-left");
	term.esc = value_addr("(escseq)");
	term.font = value_addr("font");
	term.fontbytes = value_addr("fontbytes");
	term.charmin = value_addr("char-min");
	term.charnum = value_addr("char-num");
	term.spacing = value_addr("font-spacing");

	/* Static information */
	PUSH((ucell)fontdata);
	to_word("(romfont)");
	PUSH(FONT_HEIGHT);
	to_word("(romfont-height)");
	PUSH(FONT_WIDTH);
	to_word("(romfont-width)");

	/* Initialise the structure */
	VIDEO_DICT_VALUE(video.w) = VGA_DEFAULT_WIDTH;
	VIDEO_DICT_VALUE(video.h) = VGA_DEFAULT_HEIGHT;
	VIDEO_DICT_VALUE(video.depth) = VGA_DEFAULT_DEPTH;
	VIDEO_DICT_VALUE(video.rb) = VGA_DEFAULT_LINEBYTES;
#ifndef CONFIG_TACUS
#if defined(CONFIG_QEMU) && (defined(CONFIG_PPC) || defined(CONFIG_SPARC32) || defined(CONFIG_SPARC64))
	/* If running from QEMU, grab the parameters from the firmware interface */
	int w, h, d;

	w = fw_cfg_read_i16(FW_CFG_ARCH_WIDTH);
        h = fw_cfg_read_i16(FW_CFG_ARCH_HEIGHT);
        d = fw_cfg_read_i16(FW_CFG_ARCH_DEPTH);
	if (w && h && d) {
		VIDEO_DICT_VALUE(video.w) = w;
		VIDEO_DICT_VALUE(video.h) = h;
		VIDEO_DICT_VALUE(video.depth) = d;
		VIDEO_DICT_VALUE(video.rb) = (w * ((d + 7) / 8));
	}
#endif
#endif
#if defined(CONFIG_TACUS)
		VIDEO_DICT_VALUE(video.w) = 1024;
		VIDEO_DICT_VALUE(video.h) = 768;
		VIDEO_DICT_VALUE(video.depth) = 8;
		VIDEO_DICT_VALUE(video.rb) = 1024;
#endif

	/* Setup screen-#rows/screen-#columns: they follow the screen, for this
	   boot only (the NVRAM keeps its own values) */
	snprintf(buf, sizeof(buf), FMT_ucell, VIDEO_DICT_VALUE(video.w) / FONT_WIDTH);
	push_str(buf);
	push_str("screen-#columns");
	fword("$setenv-temp");
	snprintf(buf, sizeof(buf), FMT_ucell, VIDEO_DICT_VALUE(video.h) / FONT_HEIGHT);
	push_str(buf);
	push_str("screen-#rows");
	fword("$setenv-temp");
}


#if defined(CONFIG_TACUS)

#define BIF(x,y,z) ((x>>z)&((1<<(y-z+1))-1))
#define BIK(x,y) BIF(x,y,y)

#define HWCONF_SP605 (1)     // Xilinx SP605         DVI/VGA : Chrontel CH7301C
#define HWCONF_C5G   (0x11)  // Terasic CycloneV GX  HDMI    : Analog Devices ADV7513
#define HWCONF_MiSTer (0x12) // Terasic DE10nano     HDMI    : Analog Devices ADV7513


extern volatile unsigned int *aux_reg;

volatile unsigned int *aux_iic;

static volatile int t;

static void delay(unsigned int usecs)
{
    int i;
    for (i=0;i<usecs*20;i++) t=i;
}
 
static inline void dvi_i2c_w(int scl,int sda)
{
    delay(10);
    *aux_iic=(*aux_iic & 0xFFFFFFF8) + (scl&1) + (sda&1) * 2;
}

static inline unsigned dvi_i2c_r(void)
{
    delay(10);
    return ((*aux_iic)&4)>>2;
}

static inline void dvi_i2c_wreg(unsigned a,unsigned r,unsigned v)
{
    int i;
    // START 
    dvi_i2c_w(1,1);
    dvi_i2c_w(1,0);
    dvi_i2c_w(0,0);
    // Adresse composant
    for (i=6;i>=0;i--) {
        dvi_i2c_w(0,BIK(a,i));
        dvi_i2c_w(1,BIK(a,i));
        dvi_i2c_w(0,BIK(a,i));
    }
    // Write
    dvi_i2c_w(0,0);
    dvi_i2c_w(1,0);
    dvi_i2c_w(0,0);
    // ACK
    dvi_i2c_w(0,1);
    dvi_i2c_w(1,1);
    dvi_i2c_w(0,1);
    // REGISTRE
    for (i=7;i>=0;i--) {
        dvi_i2c_w(0,BIK(r,i));
        dvi_i2c_w(1,BIK(r,i));
        dvi_i2c_w(0,BIK(r,i));
    }
    // ACK
    dvi_i2c_w(0,1);
    dvi_i2c_w(1,1);
    dvi_i2c_w(0,1); 
     // DATA
    for (i=7;i>=0;i--) {
        dvi_i2c_w(0,BIK(v,i));
        dvi_i2c_w(1,BIK(v,i));
        dvi_i2c_w(0,BIK(v,i));
    }
    // ACK
    dvi_i2c_w(0,1);
    dvi_i2c_w(1,1);
    dvi_i2c_w(0,1); 
    // STOP
    dvi_i2c_w(0,0);
    dvi_i2c_w(1,0);
    dvi_i2c_w(1,1);
}

static inline unsigned dvi_i2c_rreg(unsigned a,unsigned r)
{
    int i;
    unsigned v=0;
    // START
    dvi_i2c_w(1,1);
    dvi_i2c_w(1,0);
    dvi_i2c_w(0,0);
    // Adresse
    for (i=6; i>=0; i--) {
        dvi_i2c_w(0,BIK(a,i));
        dvi_i2c_w(1,BIK(a,i));
        dvi_i2c_w(0,BIK(a,i));
    }
    // Write
    dvi_i2c_w(0,0);
    dvi_i2c_w(1,0);
    dvi_i2c_w(0,0);
    // ACK
    dvi_i2c_w(0,1);
    dvi_i2c_w(1,1);
    dvi_i2c_w(0,1);
    // REGISTRE
    for (i=7; i>=0; i--) {
        dvi_i2c_w(0,BIK(r,i));
        dvi_i2c_w(1,BIK(r,i));
        dvi_i2c_w(0,BIK(r,i));
    }
    // ACK
    dvi_i2c_w(0,1);
    dvi_i2c_w(1,1);
    dvi_i2c_w(0,1); 
    // RESTART
    dvi_i2c_w(0,0);
    dvi_i2c_w(0,1); 
    dvi_i2c_w(1,1);
    dvi_i2c_w(1,0);
    dvi_i2c_w(0,0);
    // Adresse
    for (i=6; i>=0; i--) {
        dvi_i2c_w(0,BIK(a,i));
        dvi_i2c_w(1,BIK(a,i));
        dvi_i2c_w(0,BIK(a,i));
    }
    // Read
    dvi_i2c_w(0,1);
    dvi_i2c_w(1,1);
    dvi_i2c_w(0,1);
    // ACK
    dvi_i2c_w(0,1);
    dvi_i2c_w(1,1);
    dvi_i2c_w(0,1);
 
    // DATA
    for (i=7; i>=0; i--) {
         dvi_i2c_w(0,1);
         dvi_i2c_w(1,1);
         v=v*2+dvi_i2c_r();
         dvi_i2c_w(0,1);
    }
    // ACK bit
    dvi_i2c_w(0,1);
    dvi_i2c_w(1,1);
    dvi_i2c_w(0,1); 
    // STOP
    dvi_i2c_w(0,0);
    dvi_i2c_w(1,0);
    dvi_i2c_w(1,1);
    return v;
}

// BASED ON MiSTer "hdmi_config.sv"
uint16_t conf_adv7513[] = {
    0x4110, // Power Down control
    0x9803, // ADI required Write.
    0x9A70, // ADI required Write.
    0x9C30, // ADI required Write.
    0x9D61, // [7:4] must be b0110!.
            // [3:2] b00 = Input clock not divided. b01 = Clk divided by 2. b10 = Clk divided by 4. b11 = invalid!
            //	[1:0] must be b01!
    0xA2A4, // ADI required Write.
    0xA3A4, // ADI required Write.
    0xE0D0, // ADI required Write.
    
    0x3540, // 720p
    0x36D9,
    0x370A,
    0x3800,
    0x392D,
    0x3A00,

    0x1638, // Output Format 444 [7]=0.
            // [6] must be 0!
            // Colour Depth for Input Video data [5:4] b11 = 8-bit.
            // Input Style [3:2] b10 = Style 1 (ignored when using 444 input).
            // DDR Input Edge falling [1]=0 (not using DDR atm).
            // Output Colour Space RGB [0]=0.

//  0x16B5, // Output Format 422 [7]=1.
            // [6] must be 0!
            // Colour Depth for Input Video data [5:4] b11 = 8-bit.
            // Input Style [3:2] b01 = Style 2.
            // DDR Input Edge falling [1]=0 (not using DDR atm).
            // Output Colour Space YPrPb [0]=1.

//  0x1760, // Aspect ratio 4:3 [1]=0. DE Generation DISabled [0]=0.
            // Vsync polarity HIGH [6]=0, LOW [6]=1.
            // Hsync polarity HIGH [5]=0, LOW [5]=1.

//  0x1761, // Aspect ratio 4:3 [1]=0. DE Generation ENabled [0]=1.

//  0x1763, // Aspect ratio 16:9 [1]=1. DE Generation ENabled [0]=1.

    0x1760, // Aspect ratio 4:3  [1]=0
//  0x1762, // Aspect ratio 16:9 [1]=1

    0x1846, // CSC disabled [7]=0
            // CSC Scaling Factor [6:5] b10 = +/- 4.0, -16384 - 16380.
            // CSC Equation 3 [4:0] b00110.

//  0x3B0A, // Pixel repetition [6:5] b00 AUTO. [4:3] b01 x2 mult of input clock. [2:1] b01 x2 pixel rep to send to HDMI Rx.

    0x3B00, // Pixel repetition [6:5] b00 AUTO. [4:3] b00 x1 mult of input clock. [2:1] b00 x1 pixel rep to send to HDMI Rx.

//  0x3B6A, // Pixel repetition [6:5] b11 MANUAL. [4:3] b01 x2 mult of input clock. [2:1] b01 x2 pixel rep to send to HDMI Rx.

//  0x3C06, // VIC#6 480i-60, 2x clk, 4:3.
//  0x3C01, // VIC#1 VGA (640x480), 2x clk, 4:3.
//  0x3C02, // VIC#2 480p (720x480), 2x clk, 4:3.

    0x4000, // General Control Packet Enable

    0x4808, // [6]=0 Normal bus order!
            // [5] DDR Alignment.
            // [4:3] b01 Data right justified (for YCbCr 422 input modes).

    0x49A8, // ADI required Write.
    0x4C00, // ADI required Write.

    0x5510, // [7] must be 0!. Set RGB444 in AVinfo Frame [6:5], Set active format [4].
//  0x5550, // [7] must be 0!. Set YCbCr 444 in AVinfo Frame [6:5], Set active format [4].
//  0x5531, // [7] must be 0!. Set YCbCr 422 in AVinfo Frame [6:5].
            // AVI InfoFrame Valid [4].
            // Bar Info [3:2] b00 Bars invalid. b01 Bars vertical. b10 Bars horizontal. b11 Bars both.
            // Scan Info [1:0] b00 (No data). b01 TV. b10 PC. b11 None.

//  0x9480  // [7]=1 HPD Interrupt ENabled.

    0x7301,
    0x9400, // HPD Interrupt disabled.
    0x9902, // ADI required Write.
    0x9B18, // ADI required Write.
    0x9F00, // ADI required Write.
    0xA140, // [6]=1 Monitor Sense Power Down DISabled.
    0xA408, // ADI required Write.
    0xA504, // ADI required Write.
    0xA600, // ADI required Write.
    0xA700, // ADI required Write.
    0xA800, // ADI required Write.
    0xA900, // ADI required Write.
    0xAA00, // ADI required Write.
    0xAB40, // ADI required Write.
    0xAF16, // [7]=0 HDCP Disabled.
            // [6:5] must be b00!
            // [4]=1 Current frame IS HDCP encrypted!??? (HDCP disabled anyway?)
            // [3:2] must be b01!
            // [1]=1 HDMI Mode.
            // [0] must be b0!

    0xB900, // ADI required Write.

    0xBA60, // [7:5] Input Clock delay...
            // 000 = -1.2ns. 001 = -0.8ns. 010 = -0.4ns. 011 = No delay.
            // 100 = 0.4ns.  101 = 0.8ns.  110 = 1.2ns.  111 = 1.6ns.

    0xBB00, // ADI required Write.

    0xD6C0, // [7:6] HPD Control...
            // 00 = HPD is from both HPD pin or CDC HPD
            // 01 = HPD is from CDC HPD
            // 10 = HPD is from HPD pin
            // 11 = HPD is always high

    0xDE9C, // ADI required Write.
    0xE460, // ADI required Write.
    0xFA7D, // Nbr of times to search for good phase
    // (Audio stuff on Programming Guide, Page 66)...

    0x0A00, // [6:4] Audio Select. b000 = I2S.
            // [3:2] Audio Mode. (HBR stuff, leave at 00!).

    0x0B0E,
    0x0C04, // [7] 0 = Use sampling rate from I2S stream.   1 = Use samp rate from I2C Register.
            // [6] 0 = Use Channel Status bits from stream. 1 = Use Channel Status bits from I2C register.
            // [2] 1 = I2S0 Enable.
            // [1:0] I2S Format: 00 = Standard. 01 = Right Justified. 10 = Left Justified. 11 = AES.

    0x0D10, // [4:0] I2S Bit (Word) Width for Right-Justified.
    0x1402, // [3:0] Audio Word Length. b0010 = 16 bits.
    0x1520, // I2S Sampling Rate [7:4]. 0000 = 44.1KHz
            // I2S Sampling Rate [7:4]. 0010 = 48KHz.
            // Input ID [3:1] b000 (0) = 24-bit RGB 444 or YCrCb 444 with Separate Syncs.
            // Input ID [3:0] b0001 (1) = 16, 20, 24 bit YCbCr 4:2:2 with Separate Syncs.
            // Input ID [3:0] b0011 (3) = 16, 20, 24 bit YCbCr 4:2:2 (2x Pixel Clock, with Separate Syncs).

    // Audio Clock Config
    0x0100,
    0x0218, // 48kHz
//  0x0230, // 44kHz Set N Value 12288/6144
    0x0300, //

    0x0701, //
    0x0822, // Set CTS Value 74250
    0x090A
};


static void init_video_adv7513(void)
{
    uint8_t dh,dl;
    unsigned i;
    
    for (i=0;i<sizeof(conf_adv7513)/2;i++) {
        dh=conf_adv7513[i]>>8;
        dl=conf_adv7513[i]&255;
        dvi_i2c_wreg(0x72,dh,dl);
    }
}

static void init_video_ch7301c(void)
{
    aux_iic=aux_reg + 1;
 
    dvi_i2c_wreg(0x76,0x33,0x06);
    dvi_i2c_wreg(0x76,0x34,0x26);
    dvi_i2c_wreg(0x76,0x36,0xA0);
    dvi_i2c_wreg(0x76,0x49,0xC0);
    dvi_i2c_wreg(0x76,0x21,0x09);
}


/* probe=1 when DVI output is connected */
static int probe_video_ch7301c(void)
{
    int v;
    v=dvi_i2c_rreg(0x76,0x20);
    return (v&0x20)>>5;
}

static int probe_video_adv7513(void)
{
    if (*aux_reg & 0x40) return 1;
    return 0;
}

int probe_video(void)
{
    uint8_t hwconf=(*aux_reg >>16) & 255;
    aux_iic=aux_reg + 1;
    switch (hwconf) {
    case HWCONF_SP605:
        return probe_video_ch7301c();
    case HWCONF_C5G:
    case HWCONF_MiSTer:
    default:
        return probe_video_adv7513();
    }
}

void init_video()
{
    uint8_t hwconf=(*aux_reg >>16) & 255;
    aux_iic=aux_reg + 1;
    switch (hwconf) {
    case HWCONF_C5G:
        init_video_adv7513();
    case HWCONF_SP605:
        init_video_ch7301c();
    default:
        ;
    }
    *aux_iic=0x00172333;

#ifdef NADA
    for( i=0; i<256; i++) {
        r=((i&7) <<5);
        g=(i&0x70)<<1;
        b=(i&0x80) | (i&8)<<3;
        if (i<128) g=(~g)& 0xE0;
        if ((i&15)<8) r=(~r)& 0xE0;
        set_color( i, r*65536+g*256+b );
    }
 
    for (i=0; i<16; i++) {
        for (j=0; j<16; j++) {
            k=i*16+j;
            fill_rect(k,100+i*32,100+j*32,32,32);   
        }
    }
  
    set_color( 254, 0xffffcc );

    /* BSD Colours */
    set_color( 0,0x000000); // Black
    set_color( 1,0xAA0000); // Red
    set_color( 2,0x00AA00); // Green
    set_color( 3,0xAA5500); // Brown
    set_color( 4,0x0000AA); // Blue
    set_color( 5,0xAA00AA); // Magenta
    set_color( 6,0x00AAAA); // Cyan
    set_color( 7,0x555555); // Dark gray
    set_color( 8,0xAAAAAA); // Light gray
    set_color( 9,0xFF5555); // Light red
    set_color(10,0x55FF55); // Light green
    set_color(11,0xFFFF55); // Yellow
    set_color(12,0x5555FF); // Light blue
    set_color(13,0xFF55FF); // Light magenta
    set_color(14,0x55FFFF); // Light cyan
    set_color(15,0xFFFFFF); // White
#endif
}

#endif

