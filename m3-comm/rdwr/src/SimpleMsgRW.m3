(*                            -*- Mode: Modula-3 -*- 
 * 
 * For information about this program, contact Blair MacIntyre            
 * (bm@cs.columbia.edu) or Steven Feiner (feiner@cs.columbia.edu)         
 * at the Computer Science Dept., Columbia University,                    
 * 1214 Amsterdam Ave. Mailstop 0401, New York, NY, 10027.                
 *                                                                        
 * Copyright (C) 1995, 1996 by The Trustees of Columbia University in the 
 * City of New York.  Blair MacIntyre, Computer Science Department.       
 * See file COPYRIGHT-COLUMBIA for details.
 * 
 * Author          : Blair MacIntyre
 * Created On      : Wed Apr 19 10:16:48 1995
 * Last Modified By: Blair MacIntyre
 * Last Modified On: Sat Aug  9 13:49:10 1997
 * Update Count    : 28
 * 
 * $Source: /opt/cvs/cm3/m3-comm/rdwr/src/SimpleMsgRW.m3,v $
 * $Date: 2001-12-02 00:35:21 $
 * $Author: wagner $
 * $Revision: 1.2 $
 * 
 * $Log: not supported by cvs2svn $
 * Revision 1.1.1.1  2001/12/02 00:29:10  wagner
 * Blair MacIntyre's rdwr library
 *
 * Revision 1.3  1997/08/11 20:36:23  bm
 * Various fixes
 *
 * 
 * HISTORY
 *
 * Originally was the ConnMsgRW module in the TCP package. 
 * A small number of modifications allowed it to be adapted to sit on
 * generic Rd.T and Wr.T objects, instead of ConnFD.T objects used by
 * TCP.  The burning question is, why wasn't this done before???
 *
 * The original header in ConnMsgRW.m3 is here: *)
(* Copyright 1992 Digital Equipment Corporation. *)
(* Distributed only by permission. *)
(* Created on Sat Jan 11 15:49:00 PST 1992 by gnelson *)
(* Last modified on Wed Aug 31 12:32:14 PDT 1994 by wobber *)
(*      modified on Mon Aug 23 08:14:44 PDT 1993 by kalsow *)
(*      modified on Sun Jan 12 16:17:02 PST 1992 by meehan *)

UNSAFE MODULE SimpleMsgRW;

IMPORT Atom, AtomList;
IMPORT Rd, Wr, MsgRd, MsgWr, RdClass, WrClass, Thread;
IMPORT Swap;

(* The byte stream is divided into a sequence of fragments.  Each
   fragment has a header that consists of 4 bytes of control information
   and 4 bytes of count, followed by a sequence of data bytes.  The last
   fragment of each message has the "eom" word set it its header.  Both
   control word and count are transmitted in little-endian order (that
   is, the bytes of the integer occur in the stream in order of
   increasing significance).
   
   The {\it alignment} of a byte in a sequence is its index modulo
   eight.  The data format maintains the invariants that

    -- each data byte has the same alignment in its fragment and
       in its message, and

    -- the alignment of the first byte of each header is zero.

  This is achieved by inserting up to seven bytes of padding before
  and after each fragment.  Alignment padding is only included for
  fragments that contain one or more data byte.

  That is, given a sequence of fragments

  | f[0], ..., f[N-1]

  a message is represented by a contiguous subsequence of fragments,

  | f[p], ... f[q-1]

  where 

  | (A i: p <= i < q : f[i].eom = (i = q-1))
  | AND (p=0) OR f[p-1].eom

  The bytes of the message are the concatenation of the data bytes of
  the fragments containing the message, minus any padding introduced
  to satisfy the alignment invariants.  For example, the following code
  sets "m" to the contents of the message f[p], ...  f[q-1]:

  | VAR 
  |    m := "";
  |    skip := 0;
  |  CONST Alignment = 8;    (* at least as big as a fragment header *)

  |  BEGIN
  |    FOR i := p TO q-1 DO
  |      m := m & Text.Sub(f[i].data, skip, f[i].count);
  |      skip := skip + f[i].count MOD Alignment
  |    END
  |  END

*)

TYPE
  Int32 =  BITS 32 FOR [-16_7FFFFFFF-1..16_7FFFFFFF];
  FragmentHeader = RECORD
    (* N.B. This is in little-endian order on the wire. *)
    eom: Int32;
    nb: Int32;
  END;
  
CONST HeaderBytes = BYTESIZE(FragmentHeader);
CONST AlignBytes = HeaderBytes;

TYPE
  RdT = MsgRd.T BRANDED "SimpleMsgRW.RdT" OBJECT
    rd: Rd.T;
    hdr := FragmentHeader{eom := 1, nb := 0};
    lim: CARDINAL := 0;
  OVERRIDES
    seek := RdSeek;
    close := RdClose;
    nextMsg := RdNextMsg;
    length := Length;
  END;

(* The {\it current fragment} of "rd" is the fragment containing
   the data byte rd.buff[rd.sd+sr.cur], if "rd" is ready.  Otherwise
   the current fragment is the last fragment that has been processed
   by the reader.  The initial state reflects an artificial fragment
   with size zero that is prepended to the actual sequence of fragments
   read over the underlying stream.
   
   The value "hdr.eom" is the end of message bit for the current fragment.

   The value "hdr.nb" is the number of bytes in the current fragment that
   remain to be read from the underlying stream.
   
   The value of "lim" is one greater than the buffer index of the last
   valid stream byte in the buffer.  The value of "lim MOD 8" is
   always zero.
*)
  
TYPE
  WrT = MsgWr.T BRANDED "SimpleMsgRW.WrT" OBJECT
    wr: Wr.T;
  OVERRIDES
    seek := WrSeek;
    flush := WrFlush;
    close := WrClose;
    nextMsg := WrNextMsg;
  END;


CONST BufferSize = 8192;

VAR
  ProtocolErrorEOF: AtomList.T;
  ProtocolErrorNB: AtomList.T;

PROCEDURE NewRd(rd: Rd.T) : MsgRd.T =
  BEGIN
    <*ASSERT (BufferSize MOD AlignBytes) = 0 *>
    RETURN NEW(RdT, rd := rd, 
        buff := NEW(REF ARRAY OF CHAR, BufferSize),
        st := 0,
        lo := 0,
        hi := 0,
        cur := 0,
        intermittent := TRUE,
        seekable := FALSE,
        closed := FALSE)
  END NewRd;

PROCEDURE NewWr(wr: Wr.T) : MsgWr.T =
  BEGIN
    <*ASSERT (BufferSize MOD AlignBytes) = 0 *>
      RETURN NEW(WrT, wr := wr, 
        buff := NEW(REF ARRAY OF CHAR, BufferSize),
        st := HeaderBytes,
        lo := 0,
        hi := BufferSize - HeaderBytes,
        cur := 0,
        buffered := TRUE,
        seekable := FALSE,
        closed := FALSE)
  END NewWr;


PROCEDURE RdSeek(rd: RdT; <*UNUSED*> n: CARDINAL;
                          dontBlock: BOOLEAN): RdClass.SeekResult
  RAISES {Rd.Failure, Thread.Alerted} =
  VAR
    nb: CARDINAL;
    endian := Swap.GetEndian ();
  BEGIN
    IF dontBlock THEN RETURN RdClass.SeekResult.WouldBlock; END;
    REPEAT
      (* Advance to next sub-buffer and set "nb" to the
         number of data bytes available in it. There
         are two cases: *) 
      IF rd.hdr.nb # 0 THEN
        (* read the rest of the current fragment into the buffer *)
        rd.st := 0;
        rd.lo := rd.hi;
        rd.lim := ReadAligned(rd.rd, rd.buff);
        (* fall out into common code below *)
      ELSE
        (* advance to next non-empty fragment *) 
        rd.st := Align((rd.hi - rd.lo) + rd.st);
        rd.lo := rd.hi;
        REPEAT
          IF rd.hdr.eom # 0 THEN 
            RETURN RdClass.SeekResult.Eof; 
          END;
          IF rd.lim - rd.st < HeaderBytes THEN
            <* ASSERT rd.st = rd.lim *>
            (* read from stream to get next header *)
            rd.st := 0;
            rd.lim := ReadAligned(rd.rd, rd.buff);
          END;
          (* careful, this is endian dependent *)
          rd.hdr :=
            LOOPHOLE(ADR(rd.buff[rd.st]), UNTRACED REF FragmentHeader)^;
          IF endian = Swap.Endian.Big THEN
            rd.hdr.nb := Swap.Swap4(rd.hdr.nb);
          END;
          IF rd.hdr.nb < 0 THEN RAISE Rd.Failure(ProtocolErrorNB); END;
          INC(rd.st, HeaderBytes);
        UNTIL rd.hdr.nb # 0;
      END;
      (* Now "rd.st" is the buffer index where the data part of
         the now-current fragment begins.  This could be beyond
         the end of the buffer. *) 
      rd.st := rd.st + (rd.lo MOD AlignBytes);
      nb := MIN(rd.hdr.nb, MAX(rd.lim-rd.st, 0));
      INC(rd.hi, nb);
      DEC(rd.hdr.nb, nb);
    UNTIL nb # 0;   (* loop necessary in case hdr is at end of buffer *)
    RETURN RdClass.SeekResult.Ready;
  END RdSeek;
  
PROCEDURE Align(n: CARDINAL) : CARDINAL =
(* Round "n" up to the next multiple of 8. *) 
  BEGIN RETURN n + ((-n) MOD 8) END Align;
  
PROCEDURE ReadAligned(
    rd: Rd.T;
    buff: REF ARRAY OF CHAR) : INTEGER
  RAISES {Rd.Failure, Thread.Alerted} =
    (*
       "ReadAligned" always returns a non-zero result.
       If we are at the end of the underlying stream, then we
       have encountered a protocol error.  Otherwise, we
       return a postive count of bytes which is
       zero modulo "AlignBytes".  
    *)
  VAR 
    len := 0;
    nb: CARDINAL;  
  BEGIN
    len := 0;
    REPEAT
      (* Wait until there are characters ready by blocking on
         GetChar().  We want to repeat the CharsReady so we get the
         latest estimate of how much we can read. *)
      LOOP
        TRY
          nb := Rd.CharsReady(rd);
          IF nb = 0 THEN
            EVAL Rd.GetChar(rd);
            Rd.UnGetChar(rd);
          ELSE
            EXIT;
          END;
        EXCEPT
        | Rd.EndOfFile => RAISE Rd.Failure(ProtocolErrorEOF);
        END;
      END;
      nb := Rd.GetSub(rd, SUBARRAY(buff^, len, MIN(NUMBER(buff^)-len, nb)));
      INC(len, nb);
    UNTIL (len MOD AlignBytes) = 0;
    RETURN len;
  END ReadAligned;

PROCEDURE Length(rd: RdT) : INTEGER =
  BEGIN
    IF rd.hdr.eom # 0 THEN
      RETURN rd.lo + rd.hdr.nb;
    ELSE
      RETURN -1;
    END;
  END Length;

PROCEDURE RdClose(rd: RdT) RAISES {Rd.Failure, Thread.Alerted} =
  BEGIN
    rd.buff := NIL;
    Rd.Close(rd.rd);
  END RdClose;

PROCEDURE RdNextMsg(rd: RdT) : BOOLEAN
    RAISES {Rd.Failure, Thread.Alerted} =
  BEGIN
    (* For now, we are not going to differentiate between end
       of connection and communications failure.  This procedure
       will raise Rd.Failure in either case. *)
    WHILE rd.hdr.nb # 0 OR NOT rd.hdr.eom # 0 DO
      EVAL RdSeek(rd, rd.hi, FALSE);
    END;
    rd.st := Align((rd.hi - rd.lo) + rd.st);
    rd.cur := 0;
    rd.lo := 0;
    rd.hi := 0;
    rd.hdr := FragmentHeader{eom := 0, nb := 0};
    EVAL RdSeek(rd, rd.cur, FALSE);
    RETURN TRUE;
  END RdNextMsg;
  

PROCEDURE WrSeek(wr: WrT; <*UNUSED*> n: CARDINAL)
  RAISES {Wr.Failure, Thread.Alerted} =
  BEGIN WrFlush(wr) END WrSeek;

PROCEDURE WrFlush(wr: WrT) RAISES {Wr.Failure, Thread.Alerted} =
  BEGIN
    IF wr.cur # wr.lo THEN PutFrag(wr, FALSE); END;
    wr.st := HeaderBytes + (wr.cur MOD AlignBytes);
    wr.lo := wr.cur;
    wr.hi := wr.lo + (NUMBER(wr.buff^) - wr.st);
    Wr.Flush(wr.wr);
  END WrFlush;
  
PROCEDURE WrClose(wr: WrT) RAISES {Wr.Failure, Thread.Alerted} =
  BEGIN
    wr.buff := NIL;
    Wr.Close(wr.wr);
  END WrClose;
  
PROCEDURE WrNextMsg(wr: WrT) RAISES {Wr.Failure, Thread.Alerted} =
  BEGIN
    PutFrag(wr, TRUE);
    wr.st := HeaderBytes;
    wr.cur := 0;
    wr.lo := 0;
    wr.hi := NUMBER(wr.buff^) - HeaderBytes;
  END WrNextMsg;
  
PROCEDURE PutFrag(wr: WrT; eom: BOOLEAN) RAISES {Wr.Failure, Thread.Alerted} =
  VAR len := wr.cur - wr.lo;
      endian := Swap.GetEndian ();
  BEGIN
    WITH hdr = LOOPHOLE(ADR(wr.buff[0]), UNTRACED REF FragmentHeader) DO
      hdr^ := FragmentHeader{eom := ORD(eom), nb := len};
      IF endian = Swap.Endian.Big THEN
        hdr.nb := Swap.Swap4(hdr.nb);
      END;
    END;
    IF len = 0 THEN
      (* output just a header for null fragments *)
      Wr.PutString(wr.wr, SUBARRAY(wr.buff^, 0, HeaderBytes));
    ELSE
      (* otherwise correct for alignment of first byte *)
      Wr.PutString(wr.wr, SUBARRAY(wr.buff^, 0, Align(len+wr.st)));
    END;
    Wr.Flush(wr.wr);
  END PutFrag;
    
BEGIN
  ProtocolErrorEOF := 
    AtomList.Cons(Atom.FromText("SimpleMsgRW.UnexpectedEOF"), NIL);
  ProtocolErrorNB := 
    AtomList.Cons(Atom.FromText("SimpleMsgRW.ProtocolError"), NIL);
END SimpleMsgRW.
