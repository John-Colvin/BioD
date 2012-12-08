/*
    This file is part of BioD.
    Copyright (C) 2012    Artem Tarasov <lomereiter@gmail.com>

    BioD is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.

    BioD is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program; if not, write to the Free Software
    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

*/
module bio.bam.serialization.sam;

import bio.bam.read;
import bio.bam.reference;
import bio.bam.tagvalue;
import bio.core.utils.format;

import std.conv;
import std.algorithm;
import std.typecons;
import std.stdio;
import std.traits;
import std.c.stdlib;

import std.array;

/** Representation of tag value in SAM format
 
    Example:
    ----------
    Value v = 2.7;
    assert(toSam(v) == "f:2.7");

    v = [1, 2, 3];
    assert(toSam(v) == "B:i,1,2,3");
    ----------
*/
string toSam(V)(auto ref V v) 
    if(is(V == Value))
{
    char[] buf;
    buf.reserve(16);
    serialize(v, buf);
    return cast(string)buf;
}

/// Print SAM representation to FILE* or append it to char[]/char* 
/// (in char* case it's your responsibility to allocate enough memory)
void serialize(S)(const ref Value v, ref S stream) {

    if (v.is_numeric_array) {
        string toSamNumericArrayHelper() {
            char[] cases;
            foreach (t; ArrayElementTagValueTypes) {
                char[] loopbody = "putcharacter(stream, ',');" ~
                                  "putinteger(stream, elem);".dup;
                if (t.ch == 'f') {
                    loopbody = "append(stream, \",%g\", elem);".dup;
                }
                cases ~= `case '`~t.ch~`':` ~
                         `  putstring(stream, "B:`~t.ch~`");`~
                         `  auto arr = cast(`~t.ValueType.stringof~`[])v;`~
                         `  foreach (elem; arr) {`~loopbody~`}`~
                         `  return;`.dup;
            }
            return "switch (v.bam_typeid) { " ~ cases.idup ~ "default: assert(0); }";
        }
        mixin(toSamNumericArrayHelper());
    }
    if (v.is_integer) {
        putstring(stream, "i:");
        switch (v.bam_typeid) {
            case 'c': putinteger(stream, to!byte(v));   return;
            case 'C': putinteger(stream, to!ubyte(v));  return; 
            case 's': putinteger(stream, to!short(v));  return; 
            case 'S': putinteger(stream, to!ushort(v)); return; 
            case 'i': putinteger(stream, to!int(v));    return; 
            case 'I': putinteger(stream, to!uint(v));   return; 
            default: assert(0);
        }
    }
    if (v.is_float) {
        append(stream, "f:%g", to!float(v));
        return;
    }
    switch (v.bam_typeid) {
        case 'Z', 'H':
            putcharacter(stream, v.bam_typeid);
            putcharacter(stream, ':');
            putstring(stream, cast(string)v);
            return;
        case 'A': 
            putstring(stream, "A:");
            putcharacter(stream, to!char(v));
            return;
        default: assert(0);
    }
}

/// Get SAM representation of an alignment.
///
/// Requires providing information about reference sequences,
/// since alignment struct itself doesn't hold their names, only integer ids.
/// 
/// Example:
/// -------------
/// toSam(alignment, bam.reference_sequences);
/// -------------
string toSam(R)(auto ref R alignment, ReferenceSequenceInfo[] info) {
    char[] buf;
    buf.reserve(512);
    serialize(alignment, info, buf);
    return cast(string)buf;
}

/// Serialize $(D alignment) to FILE* or append it to char[]/char* 
/// (in char* case it's your responsibility to allocate enough memory)
void serialize(S, R)(auto ref R alignment, ReferenceSequenceInfo[] info, auto ref S stream) 
    if (is(Unqual!S == FILE*) || is(Unqual!S == char*) || is(Unqual!S == char[]))
{

    // Notice: it is extremely important to exclude pointers,
    // otherwise you'll get recursion and stack overflow.
    static if (__traits(compiles, alloca(0)) && !is(Unqual!S == char*)) {

        immutable ALLOCA_THRESHOLD = 10000;

        if (alignment.size_in_bytes < ALLOCA_THRESHOLD) {

            // surely we can allocate 50 kilobytes on the stack,
            // we're not targeting embedded systems :)
            char* buffer = cast(char*)alloca(alignment.size_in_bytes * 5);

            if (buffer != null) {
                char* p = buffer; // this pointer will be modified
                serialize(alignment, info, p);
                putstring(stream, buffer[0 .. p - buffer]);
                return;
            } else {
                debug {
                    import std.stdio;
                    writeln("WARNING: pointer allocated with alloca was null");
                }
            }
        }
    }
    
    putstring(stream, alignment.name);
    putcharacter(stream, '\t');

    putinteger(stream, alignment.flag);
    putcharacter(stream, '\t');

    if (alignment.ref_id == -1) {
        putstring(stream, "*\t");
    } else {
        putstring(stream, info[alignment.ref_id].name);
        putcharacter(stream, '\t');
    }

    putinteger(stream, alignment.position + 1);
    putcharacter(stream, '\t');

    putinteger(stream, alignment.mapping_quality);
    putcharacter(stream, '\t');

    if (alignment.cigar.length == 0) {
        putstring(stream, "*\t");
    } else {
        foreach (cigar_op; alignment.cigar) {
            putinteger(stream, cigar_op.length);
            putcharacter(stream, cigar_op.operation);
        }
        putcharacter(stream, '\t');
    }
    if (alignment.next_ref_id == alignment.ref_id) {
        if (alignment.next_ref_id == -1) {
            putstring(stream, "*\t");
        } else {
            putstring(stream, "=\t");
        }
    } else {
        if (alignment.next_ref_id == -1 ||
            info[alignment.next_ref_id].name.length == 0)
        {
            putstring(stream, "*\t");
        } else {
            putstring(stream, info[alignment.next_ref_id].name);
            putcharacter(stream, '\t');
        }
    }

    putinteger(stream, alignment.next_pos + 1);
    putcharacter(stream, '\t');

    putinteger(stream, alignment.template_length);
    putcharacter(stream, '\t');

    if (alignment.raw_sequence_data.length == 0) {
        putstring(stream, "*\t");
    } else {
        foreach(char c; alignment.sequence()) {
            putcharacter(stream, c);
        }
        putcharacter(stream, '\t');
    }
    if (alignment.phred_base_quality.length == 0 || 
        alignment.phred_base_quality[0] == '\xFF')
    {
        putcharacter(stream, '*');
    } else {
        foreach(char c; alignment.phred_base_quality) {
            putcharacter(stream, cast(char)(c + 33));
        }
    }
    
    foreach (k, v; alignment) {
        assert(k.length == 2);
        putcharacter(stream, '\t');
        putstring(stream, k);
        putcharacter(stream, ':');
        serialize(v, stream);
    }

    return;
}
