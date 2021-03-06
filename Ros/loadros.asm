;
; Pmode setup stub
; (A20 enable code and PIC reprogram from linux bootsector)
;

[ORG 0x7c00]

xor ax, ax ; make it zero
mov ds, ax
mov	di, welcome_msg
call    print_string

hang:
   jmp hang

welcome_msg	db	'Welcome',0
;
; Base address of the kernel
;
LOAD_BASE	equ     0200000h

;
; Segment selectors
;
%define KERNEL_CS     (0x8)
%define KERNEL_DS     (0x10)
%define LOADER_CS     (0x18)
%define LOADER_DS     (0x20)

struc multiboot_module
mbm_mod_start:	resd	1
mbm_mod_end:	resd	1
mbm_string:	resd	1
mbm_reserved:	resd	1
endstruc

struc multiboot_address_range
mar_baselow:    resd 1
mar_basehigh:   resd 1
mar_lengthlow:  resd 1
mar_lengthhigh:	resd 1
mar_type:       resd 1
mar_reserved:   resd 3
endstruc

;
; We are a .com program
;
;org 100h

;
; 16 bit code
;
BITS 16

%define NDEBUG 1

%macro	DPRINT	1+
%ifndef	NDEBUG
	jmp	%%end_str

%%str:	db	%1

%%end_str:
	push	di
	push	ds
	push	es
	pop	ds
	mov	di, %%str
	call	print_string
	pop	ds
	pop	di
%endif
%endmacro

entry:
	;;
	;; Load stack
	;;
	cli
	push	ds
	pop	ss
	push	ds
	pop	es
	mov	sp, real_stack_end
	sti

	;;
	;; Setup the 32-bit registers
	;;
	mov	ebx, 0
	mov	eax, 0
	mov	ecx, 0
	mov	edx, 0
	mov	esi, 0
	mov	edi, 0

	;;
	;; Set the position for the first module to be loaded
	;;
	mov	dword [next_load_base], LOAD_BASE

	;;
	;; Setup various variables
	;;
	mov	bx, ds
	movzx	eax, bx
	shl	eax, 4
	add	[gdt_base], eax

	;;
	;; Setup the loader code and data segments
	;;
	mov	eax, 0
	mov	ax, cs
	shl	eax, 4
	mov	[_loader_code_base_0_15], ax
	shr	eax, 16
	mov	byte [_loader_code_base_16_23], al

	mov	eax, 0
	mov	ax, ds
	shl	eax, 4
	mov	[_loader_data_base_0_15], ax
	shr	eax, 16
	mov	byte [_loader_data_base_16_23], al

	;;
	;; load gdt
	;;
	lgdt	[gdt_descr]

	;;
	;; Enable the A20 address line (to allow access to over 1mb)
	;;
	call	empty_8042
	mov	al, 0D1h		; command write
	out	064h, al
	call	empty_8042
	mov	al, 0DFh		; A20 on
	out	060h, al
	call	empty_8042

	;;
	;; Make the argument list into a c string
	;;
	mov	di, 081h
	mov	si, dos_cmdline
.next_char
	mov	al, [di]
	mov	[si], al
	cmp	byte [di], 0dh
	je	.end_of_command_line
	inc	di
	inc	si
	jmp	.next_char

.end_of_command_line:
	mov	byte [di], 0
	mov	byte [si], 0
	mov	[dos_cmdline_end], di

	;;
	;; Make the argument list into a c string
	;;
	mov	di, 081h
.next_char2
	cmp	byte [di], 0
	je	.end_of_command_line2
	cmp	byte [di], ' '
	jne	.not_space
	mov	byte [di], 0
.not_space
	inc	di
	jmp	.next_char2
.end_of_command_line2

	;;
	;; Check if we want to skip the first character
	;;
	cmp	byte [081h], 0
	jne	.first_char_is_zero
	mov	dx, 082h
	jmp	.start_loading
.first_char_is_zero
	mov	dx, 081h

	;;
	;; Check if we have reached the end of the string
	;;
.start_loading
	mov	bx, dx
	cmp	byte [bx], 0
	jne	.more_modules
	jmp	.done_loading

.more_modules
	;;
	;; Process the arguments
	;;
	cmp	byte [di], '/'
	jne	.no_next_module

	mov	si, _multiboot_kernel_cmdline
.find_end:
	cmp	byte [si], 0
	je	.line_end
	inc	si
	jmp	.find_end

.line_end
	mov	byte [si], ' '
	inc	si
.line_copy
	cmp	di, [dos_cmdline_end]
	je	.done_copy
	cmp	byte [di], 0
	je	.done_copy
	mov	al, byte [di]
	mov	byte [si], al
	inc	di
	inc	si
	jmp	.line_copy
.done_copy:
	mov	byte [si], 0
	jmp	.next_module
.no_next_module:

	;;
	;; Display a message saying we are loading the module
	;;
	mov	di, loading_msg
	call	print_string
	mov	di, dx
	call	print_string

	;;
	;; Save the filename
	;;
	mov	si, di
	mov	edx, 0

	mov	dx, [_multiboot_mods_count]
	shl	dx, 8
	add	dx, _multiboot_module_strings
	mov	bx, [_multiboot_mods_count]
	imul	bx, bx, multiboot_module_size
	add	bx, _multiboot_modules
	mov	eax, 0
	mov	ax, ds
	shl	eax, 4
	add	eax, edx
	mov	[bx + mbm_string], eax

	mov	bx, dx
.copy_next_char
	mov	al, [si]
	mov	[bx], al
	inc	si
	inc	bx
	cmp	al, 0
	jne	.copy_next_char

	;;
	;; Load the file
	;;
	push	di
	mov	dx, di

	; Check if it is a binary hive file
	cmp	byte [bx-5],'.'
	je	.checkForSymbol
	cmp	byte [bx-4],'.'
	je	.checkForSymbol
	cmp	byte [bx-3],'.'
	je	.checkForSymbol
	cmp	byte [bx-2],'.'
	je	.checkForSymbol

	call	sym_load_module
	jmp	.after_copy

.checkForSymbol:
	; Check if it is a symbol file
	cmp	byte [bx-5],'.'
	jne	.checkForHive
	cmp	byte [bx-4],'s'
	jne	.checkForHive
	cmp	byte [bx-3],'y'
	jne	.checkForHive
	cmp	byte [bx-2],'m'
	jne	.checkForHive

	call	sym_load_module
	jmp	.after_copy

.checkForHive:
	; Check if it is a hive file
	cmp	byte [bx-5],'.'
	jne	.checkForNls
	cmp	byte [bx-4],'h'
	jne	.checkForNls
	cmp	byte [bx-3],'i'
	jne	.checkForNls
	cmp	byte [bx-2],'v'
	jne	.checkForNls

	call	sym_load_module
	jmp	.after_copy

.checkForNls:
	; Check if it is a NLS file
	cmp	byte [bx-5],'.'
	jne	.lst_copy
	cmp	byte [bx-4],'n'
	jne	.lst_copy
	cmp	byte [bx-3],'l'
	jne	.lst_copy
	cmp	byte [bx-2],'s'
	jne	.lst_copy

	call	sym_load_module
	jmp	.after_copy

.lst_copy:
	;; Check for a module list file
	cmp	byte [bx-5],'.'
	jne	.pe_copy
	cmp	byte [bx-4],'l'
	jne	.pe_copy
	cmp	byte [bx-3],'s'
	jne	.pe_copy
	cmp	byte [bx-2],'t'
	jne	.pe_copy

	call	sym_load_module

	push	es
	mov	bx,0x9000
	push	bx
	pop	es
	xor	edi,edi

.lst_copy_bytes:
	mov	bx,_lst_name_local

.lst_byte:
	mov	al,[es:di]
	inc	di
	cmp	al,' '
	jg	.lst_not_space
	mov	byte [bx],0
	inc	bx
.lst_space:
	mov	al,[es:di]
	inc	di
	cmp	al,' '
	jle	.lst_space
.lst_not_space:
	cmp	al,'*'
	je	.lst_end
	mov	[bx],al
	inc	bx
	jmp	.lst_byte

.lst_end:
	;; We are here because the terminator was encountered
	mov	byte [bx],0		; Zero terminate
	inc	bx
	mov	byte [bx],0
	mov	[dos_cmdline_end],bx	; Put in cmd_line_length
	mov	dx,_lst_name_local; Put this address in di
	mov	di,dx			; This, too, at the start of the
					; string

	pop	es

	jmp	.start_loading

.pe_copy:
	call	pe_load_module

.after_copy:
	pop	di
	cmp	eax, 0
	jne	.load_success
	jmp	.exit
.load_success:
	mov	ah, 02h
	mov	dl, 0dh
	int	021h
	mov	ah, 02h
	mov	dl, 0ah
	int	021h

	;;
	;; Move onto the next module name in the command line
	;;
.next_module
	cmp	di, [dos_cmdline_end]
	je	.done_loading
	cmp	byte [di], 0
	je	.found_module_name
	inc	di
	jmp	.next_module
.found_module_name
	inc	di
	mov	dx, di
	jmp	.start_loading

.done_loading

	;;
	;; Initialize the multiboot information
	;;
	mov	eax, 0
	mov	ax, ds
	shl	eax, 4

	mov	[_multiboot_info_base], eax
	add	dword [_multiboot_info_base], _multiboot_info

	mov	dword [_multiboot_flags], 0xc

	mov	[_multiboot_cmdline], eax
	add	dword [_multiboot_cmdline], _multiboot_kernel_cmdline

	;;
	;; Hide the kernel's entry in the list of modules
	;;
	mov	[_multiboot_mods_addr], eax
	mov	ebx, _multiboot_modules
	add	ebx, multiboot_module_size
	add	dword [_multiboot_mods_addr], ebx
	dec	dword [_multiboot_mods_count]

	;;
	;; get extended memory size in KB
	;;
	push	ebx
	xor	ebx,ebx
	mov	[_multiboot_mem_upper],ebx
	mov	[_multiboot_mem_lower],ebx

	mov	ax, 0xe801
	int	015h
	jc	.oldstylemem

	cmp	ax, 0
	je	.cmem

	and	ebx, 0xffff
	shl	ebx,6
	mov	[_multiboot_mem_upper],ebx
	and	eax,0xffff
	add	dword [_multiboot_mem_upper],eax
	jmp	.done_mem

.cmem:
	cmp	cx, 0
	je	.oldstylemem

	and	edx, 0xFFFF
	shl	edx, 6
	mov	[_multiboot_mem_upper], edx
	and	ecx, 0xFFFF
	add	dword [_multiboot_mem_upper], ecx
	jmp	.done_mem

.oldstylemem:
	;; int 15h opt e801 don't work , try int 15h, option 88h
	mov	ah, 088h
	int	015h
	cmp	ax, 0
	je	.cmosmem
	mov	[_multiboot_mem_upper],ax
	jmp	.done_mem
.cmosmem:
	;; int 15h opt 88h don't work , try read cmos
	xor	eax,eax
	mov	al, 0x31
	out	0x70, al
	in	al, 0x71
	and	eax, 0xffff	; clear carry
	shl	eax,8
	mov	[_multiboot_mem_upper],eax
	xor	eax,eax
	mov	al, 0x30
	out	0x70, al
	in	al, 0x71
	and	eax, 0xffff	; clear carry
	add	[_multiboot_mem_lower],eax

.done_mem:

	;;
	;; Retrieve BIOS memory map if available
	;;
	xor ebx,ebx
	mov edi, _multiboot_address_ranges

.mmap_next:

	mov edx, 'PAMS'
	mov ecx, multiboot_address_range_size
	mov eax, 0E820h
	int 15h
	jc  .done_mmap

	cmp eax, 'PAMS'
	jne .done_mmap

	add edi, multiboot_address_range_size

	cmp ebx, 0
	jne .mmap_next

	;;
	;; Prepare multiboot memory map structures
	;;

	;; Fill in the address descriptor size field
	mov dword [_multiboot_address_range_descriptor_size], multiboot_address_range_size

	;; Set flag and base address and length of memory map
	or  dword [_multiboot_flags], 40h
	mov eax, edi
	sub eax, _multiboot_address_ranges
	mov dword [_multiboot_mmap_length], eax

	xor	eax, eax
	mov	ax, ds
	shl	eax, 4
	mov	[_multiboot_mmap_addr], eax
	add	dword [_multiboot_mmap_addr], _multiboot_address_ranges

.done_mmap:

	pop ebx

	;;
	;; Begin the pmode initalization
	;;

	;;
	;; Save cursor position
	;;
	mov	ax, 3		;! Reset video mode
	int	10h

	mov	bl, 10
	mov	ah, 12
	int	10h

	mov	ax, 1112h	;! Use 8x8 font
	xor	bl, bl
	int	10h
	mov	ax, 1200h	;! Use alternate print screen
	mov	bl, 20h
	int	10h
	mov	ah, 1h		;! Define cursor (scan lines 6 to 7)
	mov	cx, 0607h
	int	10h

	mov	ah, 1
	mov	cx, 0600h
	int	10h

	mov	ah, 6		; Scroll active page up
	mov	al, 32h		; Clear 50 lines
	mov	cx, 0		; Upper left of scroll
	mov	dx, 314fh	; Lower right of scroll
	mov	bh, 1*10h+1	; Use normal attribute on blanked lines
	int	10h

	mov	dx, 0
	mov	dh, 0

	mov	ah, 2
	mov	bh, 0
	int	10h

	mov	dx, 0
	mov	dh, 0

	mov	ah, 2
	mov	bh, 0
	int	10h

	mov	ah, 3
	mov	bh, 0
	int	10h
	movzx	eax, dl
;	mov	[_cursorx], eax
	movzx	eax, dh
;	mov	[_cursory], eax

	cli

	;;
	;; Load the absolute address of the multiboot information structure
	;;
	mov	ebx, [_multiboot_info_base]

	;;
	;; Enter pmode and clear prefetch queue
	;;
	mov	eax,cr0
	or	eax,0x10001
	mov	cr0,eax
	jmp	.next
.next:
	;;
	;; NOTE: This must be position independant (no references to
	;; non absolute variables)
	;;

	;;
	;; Initalize segment registers
	;;
	mov	ax,KERNEL_DS
	mov	ds,ax
	mov	ss,ax
	mov	es,ax
	mov	fs,ax
	mov	gs,ax

	;;
	;; Initalize eflags
	;;
	push	dword 0
	popf

	;;
	;; Load the multiboot magic value into eax
	;;
	mov	eax, 0x2badb002

	;;
	;; Jump to start of the kernel
	;;
	jmp	dword KERNEL_CS:(LOAD_BASE+0x1000)

	;;
	;; Never get here
	;;

.exit:
	mov	ax,04c00h
	int	21h


%include "print.asm"

STRUC	pe_doshdr
e_magic:	resw	1
e_cblp:		resw	1
e_cp:		resw	1
e_crlc:		resw	1
e_cparhdr:	resw	1
e_minalloc:	resw	1
e_maxalloc:	resw	1
e_ss:		resw	1
e_sp:		resw	1
e_csum:		resw	1
e_ip:		resw	1
e_cs:		resw	1
e_lfarlc:	resw	1
e_ovno:		resw	1
e_res:		resw	4
e_oemid:	resw	1
e_oeminfo:	resw	1
e_res2:		resw	10
e_lfanew:	resd	1
ENDSTRUC


_mb_magic:
	dd 0
_mb_flags:
	dd 0
_mb_checksum:
	dd 0
_mb_header_addr:
	dd 0
_mb_load_addr:
	dd 0
_mb_load_end_addr:
	dd 0
_mb_bss_end_addr:
	dd 0
_mb_entry_addr:
	dd 0

_cpe_doshdr:
	times pe_doshdr_size db 0
_current_filehandle:
	dw 0
_current_size:
	dd 0
_current_file_size:
	dd 0

_lst_name_local:
	times 2048 db 0

	;;
	;; Load a SYM file
	;;	DS:DX = Filename
	;;
sym_load_module:
	call	load_module1
	call	load_module2
	mov	edi, [next_load_base]
	add	edi, [_current_file_size]

	mov	eax, edi
	test	di, 0xfff
	jz	.sym_no_round
	and	di, 0xf000
	add	edi, 0x1000

	;;
	;; Clear unused space in the last page
	;;
	mov	esi, edi
	mov	ecx, edi
	sub	ecx, eax

.sym_clear:
	mov	byte [esi],0
	inc	esi
	loop	.sym_clear

.sym_no_round:

	call	load_module3
	ret

	;;
	;; Load a PE file
	;;	DS:DX = Filename
	;;
pe_load_module:
	call	load_module1

	;;
	;; Read in the DOS EXE header
	;;
	mov	ah, 0x3f
	mov	bx, [_current_filehandle]
	mov	cx, pe_doshdr_size
	mov	dx, _cpe_doshdr
	int	0x21
	jnc	.header_read
	mov	di, error_file_read_failed
	jmp	error
.header_read

	;;
	;; Check the DOS EXE magic
	;;
	mov	ax, word [_cpe_doshdr + e_magic]
	cmp	ax, 'MZ'
	je	.mz_hdr_good
	mov	di, error_bad_mz
	jmp	error
.mz_hdr_good

	;;
	;; Find the BSS size
	;;
	mov	ebx, dword [_multiboot_mods_count]
	cmp	ebx, 0
	jne	.not_first

	mov	edx, 0
	mov	ax, 0x4200
	mov	cx, 0
	mov	dx, 0x1004
	mov	bx, [_current_filehandle]
	int	0x21
	jnc	.start_seek1
	mov	di, error_file_seek_failed
	jmp	error
.start_seek1:
	mov	ah, 0x3F
	mov	bx, [_current_filehandle]
	mov	cx, 32
	mov	dx, _mb_magic
	int	0x21
	jnc	.mb_header_read
	mov	di, error_file_read_failed
	jmp	error
.mb_header_read:
	jmp	.first

.not_first:
	mov	dword [_mb_bss_end_addr], 0
.first:

	call  load_module2
	call  load_module3
	ret

load_module1:
	;;
	;; Open file
	;;
	mov	ax, 0x3d00
	int	0x21
	jnc	.file_opened
	mov	di, error_file_open_failed
	jmp	error
.file_opened:

	;;
	;; Save the file handle
	;;
	mov	[_current_filehandle], ax

	;;
	;; Print space
	;;
	mov	ah,02h
	mov	dl,' '
	int	021h

	;;
	;; Seek to the start of the file
	;;
	mov	ax, 0x4200
	mov	bx, [_current_filehandle]
	mov	cx, 0
	mov	dx, 0
	int	0x21
	jnc	.seek_start
	mov	di, error_file_seek_failed
	jmp	error
.seek_start:
	ret

load_module2:
	;;
	;; Seek to the end of the file to get the file size
	;;
	mov	edx, 0
	mov	ax, 0x4202
	mov	dx, 0
	mov	cx, 0
	mov	bx, [_current_filehandle]
	int	0x21
	jnc	.start_end
	mov	di, error_file_seek_failed
	jmp	error
.start_end
	shl	edx, 16
	mov	dx, ax
	mov	[_current_size], edx
	mov	[_current_file_size], edx

	mov	edx, 0
	mov	ax, 0x4200
	mov	dx, 0
	mov	cx, 0
	mov	bx, [_current_filehandle]
	int	0x21
	jnc	.start_seek
	mov	di, error_file_seek_failed
	jmp	error
.start_seek

	mov	edi, [next_load_base]

.read_next:
	cmp	dword [_current_size], 32768
	jle	.read_tail

	;;
	;; Read in the file data
	;;
	push	ds
	mov	ah, 0x3f
	mov	bx, [_current_filehandle]
	mov	cx, 32768
	mov	dx, 0x9000
	mov	ds, dx
	mov	dx, 0
	int	0x21
	jnc	.read_data_succeeded
	pop	ds
	mov	di, error_file_read_failed
	jmp	error
.read_data_succeeded:
%ifndef NDEBUG
	mov	ah,02h
	mov	dl,'#'
	int	021h
%endif

	;;
	;; Copy the file data just read in to high memory
	;;
	pop	ds
	mov	esi, 0x90000
	mov	ecx, 32768
	call	_himem_copy
%ifndef NDEBUG
	mov	ah,02h
	mov	dl,'$'
	int	021h
%else
	mov	ah,02h
	mov	dl,'.'
	int	021h
%endif

	sub	dword [_current_size], 32768
	jmp	.read_next

.read_tail
	;;
	;; Read in the tailing part of the file data
	;;
	push	ds
	mov	eax, [_current_size]
	mov	cx, ax
	mov	ah, 0x3f
	mov	bx, [_current_filehandle]
	mov	dx, 0x9000
	mov	ds, dx
	mov	dx, 0
	int	0x21
	jnc	.read_last_data_succeeded
	pop	ds
	mov	di, error_file_read_failed
	jmp	error
.read_last_data_succeeded:
	;;
	;; Close the file
	;;
	pop	ds
	mov	bx, [_current_filehandle]
	mov	ah, 0x3e
	int	0x21
%ifndef NDEBUG
	mov	ah,02h
	mov	dl,'#'
	int	021h
%endif

	;;
	;; Copy the tailing part to high memory
	;;
	mov	ecx, [_current_size]
	mov	esi, 0x90000
	call	_himem_copy
%ifndef NDEBUG
	mov	ah,02h
	mov	dl,'$'
	int	021h
%else
	mov	ah,02h
	mov	dl,'.'
	int	021h
%endif

	mov	edx, [_mb_bss_end_addr]
	cmp	edx, 0
	je	.no_bss
	mov	edi, edx
.no_bss:
	test	di, 0xfff
	jz	.no_round
	and	di, 0xf000
	add	edi, 0x1000
.no_round:
	ret

load_module3:
	mov	bx, [_multiboot_mods_count]
	imul	bx, bx, multiboot_module_size
	add	bx, _multiboot_modules

	mov	edx, [next_load_base]
	mov	[bx + mbm_mod_start], edx
	mov	[bx + mbm_mod_end], edi
	mov	[next_load_base], edi
	mov	dword [bx + mbm_reserved], 0

	inc	dword [_multiboot_mods_count]

	mov	eax, 1

	ret

	;;
	;; On error print a message and return zero
	;;
error:
	call	print_string
	mov	ax,04c00h
	int	21h

	;;
	;; Copy to high memory
	;; ARGUMENTS
	;;	ESI = Source address
	;;	EDI = Destination address
	;;	ECX = Byte count
	;; RETURNS
	;;	EDI = End of the destination region
	;;	ECX = 0
	;;
_himem_copy:
	push	ds		; Save DS
	push	es		; Save ES
	push	eax
	push	esi

	cmp	eax, 0
	je	.l3

	cli			; No interrupts during pmode

	mov	eax, cr0	; Entered protected mode
	or	eax, 0x1
	mov	cr0, eax

	jmp	.l1		; Flush prefetch queue
.l1:

	mov	eax, KERNEL_DS	; Load DS with a suitable selector
	mov	ds, ax
	mov	eax, KERNEL_DS
	mov	es, ax

	cld
	a32 rep	movsb
;.l2:
;	mov	al, [esi]	; Copy the data
;	mov	[edi], al
;	dec	ecx
;	inc	esi
;	inc	edi
;	cmp	ecx, 0
;	jne	.l2

	mov	eax, cr0	; Leave protected mode
	and	eax, 0xfffffffe
	mov	cr0, eax

	jmp	.l3
.l3:
	sti
	pop	esi
	pop	eax
	pop	es
	pop	ds
	ret

;
; Loading message
;
loading_msg	db	'Loading: ',0

;;
;; Next free address in high memory
;;
next_load_base dd 0

;
; Needed for enabling the a20 address line
;
empty_8042:
	jmp	empty_8042_1
empty_8042_1:
	jmp	empty_8042_2
empty_8042_2:
	in	al,064h
	test	al,02h
	jnz	empty_8042
	ret

;
; GDT descriptor
;
align 8
gdt_descr:
gdt_limit:
	dw	(5*8)-1
gdt_base:
	dd	_gdt

	;;
	;; Our initial stack
	;;
real_stack times 1024 db 0
real_stack_end:

	;;
	;; DOS commandline buffer
	;;
dos_cmdline times 256 db 0
dos_cmdline_end dw 0

	;;
	;; Boot information structure
	;;
_multiboot_info_base:
	dd	0x0

_multiboot_info:
_multiboot_flags:
	dd	0x0
_multiboot_mem_lower:
	dd	0x0
_multiboot_mem_upper:
	dd	0x0
_multiboot_boot_device:
	dd	0x0
_multiboot_cmdline:
	dd	0x0
_multiboot_mods_count:
	dd	0x0
_multiboot_mods_addr:
	dd	0x0
_multiboot_syms:
	times 12 db 0
_multiboot_mmap_length:
	dd	0x0
_multiboot_mmap_addr:
	dd	0x0
_multiboot_drives_count:
	dd	0x0
_multiboot_drives_addr:
	dd	0x0
_multiboot_config_table:
	dd	0x0
_multiboot_boot_loader_name:
	dd	0x0
_multiboot_apm_table:
	dd	0x0

_multiboot_modules:
	times (64*multiboot_module_size) db 0
_multiboot_module_strings:
	times (64*256) db 0

_multiboot_address_range_descriptor_size dd 0

_multiboot_address_ranges:
	times (64*multiboot_address_range_size) db 0

_multiboot_kernel_cmdline:
	db 'multi(0)disk(0)rdisk(0)partition(1)\reactos'
	times 255-($-_multiboot_kernel_cmdline) db 0

%include "gdt.asm"
