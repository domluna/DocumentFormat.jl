# TODO: strip extra newlines in merge_edits
# TODO: be able to figure out current line_offset even in a nest
#
# loc = cursor_loc(s)
# n_ws = first(findfirst(x -> !isspace(x), s.doc.text[s.doc.ranges[loc[1]]])) - 1
# line_offset = loc[2] - n_ws + s.indents * s.indent_width
#
# then check if line_offset + x.span/fullspan <= s.max_width
#
# this works if there's no nest
#
# basically need a cursor_loc function that works even in a nest
#
# ###
# ### Nesting
# ###
#
# types to nest right to left
#
# BinaryOpSyntaxCall/BinaryOpCall (=, |, ||, &, &&)
# Conditional
# WhereOpCall [x]
# ChainOpCall [?]
# Comparison [?]
#
# types to nest left to right
#
# Return
# MacroCall
# Call [x]
# Parameters [x]
# TupleH [x]
# Vect [x]
# Export [x]
# Import [x]
# Using [x]
#
# unsure (?)
#
# pretty(x, s)
#
# o (line_offset) is length(Edit(x))

struct Document
    text::AbstractString
    ranges::Vector{UnitRange{Int}}
end

mutable struct State
    indent_width::Int
    max_width::Int
    indents::Int
    offset::Int
    # 0 indicates the start of the line
    line_offset::Int
    doc::Document
end

function newline_ranges(text::String)
    ranges = UnitRange{Int}[]
    for t in CSTParser.Tokenize.tokenize(text)
        if t.kind == Tokens.WHITESPACE
            offset = t.startbyte
            for c in t.val
                if c == '\n'
                    s = length(ranges) > 0 ? last(ranges[end]) + 1 : 1
                    push!(ranges, s:offset+1)
                end
                offset += 1
            end
        elseif t.kind == Tokens.ENDMARKER
            s = length(ranges) > 0 ? last(ranges[end]) + 1 : 1
            push!(ranges, s:t.startbyte)
        elseif (t.kind == Tokens.TRIPLE_STRING || t.kind == Tokens.STRING) && t.startpos[1] != t.endpos[1]
            offset = t.startbyte
            nls = findall(x -> x == '\n', t.val)
            for nl in nls
                s = length(ranges) > 0 ? last(ranges[end]) + 1 : 1
                push!(ranges, s:offset+nl)
            end
        end
    end
    ranges
end

function cursor_loc(s::State, offset::Int)
    for (l, r) in enumerate(s.doc.ranges)
        if offset in r
            return (l, offset - first(r) + 1, length(r))
        end
    end
    error("indexing range 1 - $(last(s.doc.ranges[end])), index used = $(offset)")
end
cursor_loc(s::State) = cursor_loc(s, s.offset)


struct Edit
    startline::Int
    endline::Int
    text::AbstractString
end
Base.length(e::Edit) = length(e.text)

# Returns an Edit, a prettified text representation of x
# along with the lines containing x in the original file.
#
# a
#
# comment 1
#
# comment 2
#
# b
#
function merge_edits(a::Edit, b::Edit, s::State; join_lines=false, custom_indent=0)
    #= @info "Edit A", a, "Edit B", b =#

    if (a.startline == b.startline || a.endline == b.endline) && custom_indent == 0
        text = a.text
        text *= b.text == "end" ? " " * b.text : b.text
        #= @info "HERE", a.text, b.text =#
        return Edit(a.startline, b.endline, text)
    end

    w = repeat(" ", custom_indent == 0 ? s.indents * s.indent_width : custom_indent)
    #= w = repeat(" ",  s.indents * s.indent_width + custom_indent) =#
    #= @info "INDENT_WIDTH", length(w), "CUSTOM INDENT", custom_indent =#
    # Due to the way CSTParser parses if statements, by default the condition
    # after the elseif keyword will be on a newline. For this reason we
    # handle merging elseif keyword expliticly.
    text = ""
    if a.text == ""
    elseif a.text == "\n"
        s.line_offset = length(w)
    elseif endswith(a.text, "elseif")
        text = a.text * " "
    elseif a.text[end] != "\n" && !join_lines
        @info "JOINING LINES", a.text
        text *= rstrip(a.text, ' ') * "\n" * w
        s.line_offset = length(w)
    else
        text *= a.text
    end

    # comments shouldn't be in between joinable lines anyway
    if !join_lines
        for l in a.endline+1:b.startline-1
            v = s.doc.text[s.doc.ranges[l]]
            if v == "\n"
                text *= v * w
                continue
            end
            i = first(findfirst(x -> !isspace(x), v))
            if v[i] == '#'
                text *= v[i:end] * w
            else
                # This captures the possible additional indentation in a docstring
                i = max(min(i, s.indents-1 * s.indent_width), 1)
                text *= v[i:end] * w
            end
        end
    end

    text *= b.text
    Edit(a.startline, b.endline, text)
end

function merge_edits(a::AbstractString, b::AbstractString, s::State; kwargs...)
    l, _, _ = cursor_loc(s)
    merge_edits(Edit(l, l, a), Edit(l, l, b), s; kwargs...)
end

Base.:*(a::Edit, b::AbstractString) = Edit(a.startline, a.endline, a.text * b)
Base.:*(a::AbstractString, b::Edit) = Edit(b.startline, b.endline, a * b.text)
merge_edits(a::Edit, b::AbstractString, s::State; kwargs...) = merge_edits(a, Edit(a.startline, a.endline, b), s; kwargs...)
merge_edits(a::AbstractString, b::Edit, s::State; kwargs...) = merge_edits(Edit(b.startline, b.endline, a), b, s; kwargs...)

function pretty(x::T, s::State, custom_indent=0) where T <: Union{CSTParser.AbstractEXPR, Vector}
    e = ""
    for a in x
        e = merge_edits(e, pretty(a, s, custom_indent), s)
    end
    e
end

function pretty(x::CSTParser.IDENTIFIER, s::State, custom_indent=0)
    loc = cursor_loc(s)
    s.offset += x.fullspan
    s.line_offset += length(x.val)
    Edit(loc[1], loc[1], x.val)
end

function pretty(x::CSTParser.OPERATOR, s::State, custom_indent=0)
    loc = cursor_loc(s)
    text = string(CSTParser.Expr(x))
    s.offset += x.fullspan
    s.line_offset += length(text)
    Edit(loc[1], loc[1], text)
end

function pretty(x::CSTParser.KEYWORD, s::State, custom_indent=0)
    loc = cursor_loc(s)
    text = ""
    text = x.kind == Tokens.ABSTRACT ? "abstract " :
        x.kind == Tokens.BAREMODULE ? "baremodule " :
        x.kind == Tokens.BEGIN ? "begin" :
        x.kind == Tokens.BREAK ? "break" :
        x.kind == Tokens.CATCH ? "catch" :
        x.kind == Tokens.CONST ? "const " :
        x.kind == Tokens.CONTINUE ? "continue" :
        x.kind == Tokens.DO ? " do " :
        x.kind == Tokens.ELSE ? "else" :
        x.kind == Tokens.ELSEIF ? "elseif" :
        x.kind == Tokens.END ? "end" :
        x.kind == Tokens.EXPORT ? "export " :
        x.kind == Tokens.FINALLY ? "finally" :
        x.kind == Tokens.FOR ? "for" :
        x.kind == Tokens.FUNCTION ? "function " :
        x.kind == Tokens.GLOBAL ? "global " :
        x.kind == Tokens.IF ? "if" :
        x.kind == Tokens.IMPORT ? "import " :
        x.kind == Tokens.IMPORTALL ? "importall " :
        x.kind == Tokens.LET ? "let" :
        x.kind == Tokens.LOCAL ? "local " :
        x.kind == Tokens.MACRO ? "macro " :
        x.kind == Tokens.MODULE ? "module " :
        x.kind == Tokens.MUTABLE ? "mutable " :
        x.kind == Tokens.OUTER ? "outer " :
        x.kind == Tokens.PRIMITIVE ? "primitive " :
        x.kind == Tokens.QUOTE ? "quote" :
        x.kind == Tokens.RETURN ? "return" :
        x.kind == Tokens.STRUCT ? "struct " :
        x.kind == Tokens.TRY ? "try" :
        x.kind == Tokens.TYPE ? "type " :
        x.kind == Tokens.USING ? "using " :
        x.kind == Tokens.WHILE ? "while" : ""
    s.offset += x.fullspan
    s.line_offset += length(text)
    Edit(loc[1], loc[1], text)
end

function pretty(x::CSTParser.PUNCTUATION, s::State, custom_indent=0)
    loc = cursor_loc(s)
    text = x.kind == Tokens.LPAREN ? "(" :
        x.kind == Tokens.LBRACE ? "{" :
        x.kind == Tokens.LSQUARE ? "[" :
        x.kind == Tokens.RPAREN ? ")" :
        x.kind == Tokens.RBRACE ? "}" :
        x.kind == Tokens.RSQUARE ? "]" :
        x.kind == Tokens.COMMA ? "," :
        x.kind == Tokens.SEMICOLON ? ";" :
        x.kind == Tokens.AT_SIGN ? "@" :
        x.kind == Tokens.DOT ? "." : ""
    s.offset += x.fullspan
    s.line_offset += length(text)
    Edit(loc[1], loc[1], text)
end

function pretty(x::CSTParser.LITERAL, s::State, custom_indent=0; surround_with_quotes=true)
    loc = cursor_loc(s)
    text = x.kind == Tokens.TRIPLE_STRING && surround_with_quotes ? "\"\"\"" * escape_string(x.val, "\$") * "\"\"\"" :
           x.kind == Tokens.STRING && surround_with_quotes ? "\"" * escape_string(x.val, "\$") * "\"" :
           x.val
    s.offset += x.fullspan
    s.line_offset += length(text)
    Edit(loc[1], loc[1], text == "" ? "\n" : text)
end

function pretty(x::CSTParser.EXPR{CSTParser.StringH}, s::State, custom_indent=0)
    e = ""
    for a in x
        if a isa CSTParser.LITERAL
            e = merge_edits(e, pretty(a, s, custom_indent; surround_with_quotes=false), s)
        else
            e = merge_edits(e, pretty(a, s, custom_indent), s)
        end
    end
    Edit(e.startline, e.endline, "\"" * escape_string(e.text) * "\"")
end

function pretty(x::CSTParser.EXPR{CSTParser.MacroCall}, s::State, custom_indent=0)
    if x.args[1] isa CSTParser.EXPR{CSTParser.GlobalRefDoc}
        pretty(x.args[1], s)

        o = s.offset
        loc1 = cursor_loc(s)
        s.offset += x.args[2].fullspan
        loc2 = cursor_loc(s, s.offset-1)
        #= @info "DOC POSITION START", loc1 =#
        #= @info "DOC POSITION END", loc2 =#

        tq = "\"\"\""
        w = repeat(" ", s.indent_width * s.indents)
        is_ts = startswith(s.doc.text[o:o+loc1[3]-loc1[2]], tq)
        quote_len = is_ts ? 3 : 1
        #= @info "STARTS WITH TRIPLE QUOTES", is_ts =#

        e = Edit(loc1[1], loc1[1], tq)

        if loc1[3] - loc1[2] > quote_len
            sidx = is_ts ? o + 3 : o + 1
            if loc1[1] == loc2[1]
                eidx = is_ts ? o+loc1[3]-loc1[2]-4 : o+loc1[3]-loc1[2]-2
                v = s.doc.text[sidx:eidx]
                #= @info "H1", v =#
            else
                #= eidx = is_ts ? o+loc1[3]-loc1[2]-1 : o+loc1[3]-loc1[2]-1 =#
                eidx = o+loc1[3]-loc1[2]-1
                v = s.doc.text[sidx:eidx]
                #= @info "H2", v =#
            end
            e = merge_edits(e, Edit(loc1[1], loc1[1], "\n" * w * v), s)
        end

        o = s.offset

        if loc1[1] == loc2[1]
            e = merge_edits(e, Edit(loc2[1]+1, loc2[1]+1, tq), s)
        elseif loc2[3] > quote_len + 1
            v = strip(is_ts ? s.doc.text[o-loc2[2]:o-5] : s.doc.text[o-loc2[2]:o-3])
            #= @info "H3", v =#
            if v  != ""
                e = merge_edits(e, Edit(loc2[1], loc2[1], v * "\n" * w * tq), s)
            else
                e = merge_edits(e, Edit(loc2[1], loc2[1], tq), s)
            end
        else
            e = merge_edits(e, Edit(loc2[1], loc2[1], tq), s)
        end

        return merge_edits(e, pretty(x.args[3], s, custom_indent), s)
    end

    loc = cursor_loc(s)
    e = ""
    for (i, a) in enumerate(x)
        # Macro calls can be whitespace sensitive
        ei = pretty(a, s, custom_indent)
        if i == 1 || i == 2
            o = s.offset
            loc = cursor_loc(s)
            if startswith(s.doc.text[o:o+loc[3]-loc[2]], ei.text * " ")
                e = merge_edits(e, ei, s) * " "
                s.line_offset += 1
            else
                e = merge_edits(e, ei, s)
            end
        elseif i == length(x) - 1 && a isa CSTParser.PUNCTUATION && x.args[i+1] isa CSTParser.PUNCTUATION
            e = merge_edits(e, ei, s; join_lines=true)
        elseif a isa CSTParser.PUNCTUATION && a.kind == Tokens.COMMA && i != length(x)
            e = merge_edits(e, ei * " ", s; join_lines=true)
            s.line_offset += 1
        else
            e = merge_edits(e, ei, s; join_lines=true)
        end
    end
    e
end

function pretty(x::CSTParser.EXPR{CSTParser.Block}, s::State, custom_indent=0; ignore_single_line=false)
    #= @info "INDENT START", s.indent_width * s.indents =#
    sl = !ignore_single_line ? cursor_loc(s)[1] == cursor_loc(s, s.offset+x.fullspan-1)[1] : false
    #= @info "SINGLE LINE BLOCK", x, length(x) =#
    e = ""
    for (i, a) in enumerate(x)
        !sl && (s.line_offset = s.indents * s.indent_width)
        ei = pretty(a, s, custom_indent)
        if i == length(x) - 1 && a isa CSTParser.PUNCTUATION && x.args[i+1] isa CSTParser.PUNCTUATION
            e = merge_edits(e, ei, s)
        elseif a isa CSTParser.PUNCTUATION && a.kind == Tokens.COMMA && i != length(x)
            e = merge_edits(e, ei * " ", s)
            s.line_offset += 1
        elseif sl
            if i == 1
                e = merge_edits(e, ei, s)
            else
                s.line_offset += 2
                e = merge_edits(e, "; " * ei, s)
            end
        else
            e = merge_edits(e, ei, s)
        end
    end
    #= @info "INDENT END", s.indent_width * s.indents =#
    e
end

function pretty(x::CSTParser.EXPR{CSTParser.FunctionDef}, s::State, custom_indent=0)
    e = merge_edits(pretty(x.args[1], s), pretty(x.args[2], s, custom_indent), s; join_lines=true)
    if length(x) > 3
        sl = cursor_loc(s)[1] == cursor_loc(s, s.offset+x.args[3].fullspan+x.args[4].span-1)[1]
        sl && x.args[3].fullspan != 0 && (e *= " "; s.line_offset += 1)
        s.indents += 1
        e = merge_edits(e, pretty(x.args[3], s, custom_indent), s)
        s.indents -= 1
        e = merge_edits(e, pretty(x.args[4], s, custom_indent), s)
    else
        e = merge_edits(e, pretty(x.args[3], s, custom_indent), s)
    end
    e
end

function pretty(x::CSTParser.EXPR{T}, s::State, custom_indent=0) where T <: Union{CSTParser.Macro,CSTParser.Struct}
    e = merge_edits(pretty(x.args[1], s), pretty(x.args[2], s, custom_indent), s; join_lines=true)
    sl = cursor_loc(s)[1] == cursor_loc(s, s.offset+x.args[3].fullspan+x.args[4].span-1)[1]
    sl && x.args[3].fullspan != 0 && (e *= " "; s.line_offset += 1)
    s.indents += 1
    e = merge_edits(e, pretty(x.args[3], s), s, custom_indent)
    s.indents -= 1
    merge_edits(e, pretty(x.args[4], s), s, custom_indent)
end

function pretty(x::CSTParser.EXPR{T}, s::State, custom_indent=0) where T <: Union{CSTParser.For,CSTParser.While}
    e = pretty(x.args[1], s)
    if x.args[2] isa CSTParser.EXPR{CSTParser.Block}
        s.line_offset += 1
        e = merge_edits(e, " " * pretty(x.args[2], s, custom_indent; ignore_single_line=true), s; join_lines=true)
    else
        s.line_offset += 1
        e = merge_edits(e, " " * pretty(x.args[2], s, custom_indent), s; join_lines=true)
    end
    sl = cursor_loc(s)[1] == cursor_loc(s, s.offset+x.args[3].fullspan+x.args[4].span-1)[1]
    sl && x.args[3].fullspan != 0 && (e *= " "; s.line_offset += 1)
    s.indents += 1
    e = merge_edits(e, pretty(x.args[3], s, custom_indent), s)
    s.indents -= 1
    merge_edits(e, pretty(x.args[4], s, custom_indent), s)
end


function pretty(x::CSTParser.EXPR{CSTParser.Abstract}, s::State, custom_indent=0)
    e = merge_edits(pretty(x.args[1], s), pretty(x.args[2], s), s; join_lines=true)
    e = merge_edits(e, pretty(x.args[3], s), s; join_lines=true)
    s.line_offset += 1
    e = merge_edits(e, " " * pretty(x.args[4], s), s; join_lines=true)
end

function pretty(x::CSTParser.EXPR{CSTParser.Mutable}, s::State, custom_indent=0)
    e = merge_edits(pretty(x.args[1], s), pretty(x.args[2], s), s; join_lines=true)
    e = merge_edits(e, pretty(x.args[3], s, custom_indent), s; join_lines=true)
    sl = cursor_loc(s)[1] == cursor_loc(s, s.offset+x.args[4].fullspan+x.args[5].span-1)[1]
    sl && x.args[4].fullspan != 0 && (e *= " "; s.line_offset += 1)
    s.indents += 1
    e = merge_edits(e, pretty(x.args[4], s, custom_indent), s)
    s.indents -= 1
    merge_edits(e, pretty(x.args[5], s, custom_indent), s)
end


function pretty(x::CSTParser.EXPR{CSTParser.Do}, s::State, custom_indent=0)
    e = pretty(x.args[1:3], s, custom_indent)
    if x.args[4] isa CSTParser.EXPR{CSTParser.Block}
        s.indents += 1
        e = merge_edits(e, pretty(x.args[4], s, custom_indent), s)
        s.indents -= 1
        e = merge_edits(e, pretty(x.args[5], s, custom_indent), s)
    else
        e = merge_edits(e, pretty(x.args[4], s, custom_indent), s)
    end
    e
end

function pretty(x::CSTParser.EXPR{CSTParser.Try}, s::State, custom_indent=0)
    e = pretty(x.args[1], s)
    s.indents += 1
    e = merge_edits(e, pretty(x.args[2], s, custom_indent), s)
    s.indents -= 1
    e = merge_edits(e, pretty(x.args[3], s), s)
    if x.args[4].fullspan != 0
        s.line_offset += 1
        e = merge_edits(e, " " * pretty(x.args[4], s), s; join_lines=true)
    end
    s.indents += 1
    e = merge_edits(e, pretty(x.args[5], s, custom_indent), s)
    s.indents -= 1
    e = merge_edits(e, pretty(x.args[6], s), s)
    if length(x.args) > 6
        s.indents += 1
        e = merge_edits(e, pretty(x.args[7], s, custom_indent), s)
        s.indents -= 1
        e = merge_edits(e, pretty(x.args[8], s), s)
    end
    e
end

function pretty(x::CSTParser.EXPR{CSTParser.ModuleH}, s::State, custom_indent=0)
    e = merge_edits(pretty(x.args[1], s), pretty(x.args[2], s), s; join_lines=true)
    sl = cursor_loc(s)[1] == cursor_loc(s, s.offset+x.args[3].fullspan+x.args[4].span-1)[1]
    sl && x.args[3].fullspan != 0 && (e *= " "; s.line_offset += 1)
    merge_edits(e, pretty(x.args[3:4], s), s)
end


function pretty(x::T, s::State, custom_indent=0) where T <: Union{CSTParser.BinaryOpCall,CSTParser.BinarySyntaxOpCall}
    e = pretty(x.arg1, s, custom_indent)
    @info typeof(x), custom_indent, s.line_offset, x.op.kind
    if CSTParser.precedence(x.op) in (8, 13, 14, 16) && x.op.kind != Tokens.ANON_FUNC
        e = merge_edits(e, pretty(x.op, s), s; join_lines=true)
    elseif x.op.kind == Tokens.EX_OR
        s.line_offset += 1
        e = merge_edits(e, " " * pretty(x.op, s), s, join_lines=true)
    else
        s.line_offset += 1
        e = merge_edits(e, " " * pretty(x.op, s) * " ", s, join_lines=true)
        s.line_offset += 1
    end
    merge_edits(e, pretty(x.arg2, s, custom_indent), s; join_lines=true)
end

# C ? E1 : E2
#
# if the above is > s.max_width
# format to
#
# C ? E1 :
# E2
#
# still doesn't fit?
#
# C ?
# E1 :
# E2
#
# C1 ? E1 : C2 ? E2 : C3 ? E3 : C4 ? E4 : E5
#
# [C1 ?, E1 :, C2 ? E2 : C3 ? E3 : C4 ? E4 : E5]
# [C2 ?, E2 :, C3 ? E3 : C4 ? E4 : E5]
# [C3 ?, E3 :, C4 ? E4 : E5]
# [C4 ?, E4 :, E5]
function pretty(x::CSTParser.ConditionalOpCall, s::State, custom_indent=0)
    line_offset = s.line_offset
    custom_indent += custom_indent == 0 ? line_offset : 0
    edits = Edit[]
    line_width = custom_indent == 0 ? line_offset : custom_indent

    @info "$(typeof(x)) line_width = $(line_width), custom_indent = $(custom_indent)"#, edits[1].text

    e = pretty(x.cond, s, custom_indent)
    custom_indent == 0 && (custom_indent += length(e) - 1)
    s.line_offset += 1
    e = merge_edits(e, " " * pretty(x.op1, s) * " ", s; join_lines=true)
    s.line_offset += 1
    push!(edits, e)

    e = pretty(x.arg1, s, custom_indent)
    s.line_offset += 1
    e = merge_edits(e, " " * pretty(x.op2, s) * " ", s; join_lines=true)
    s.line_offset += 1
    push!(edits, e)
    push!(edits, pretty(x.arg2, s, custom_indent))

    #= e = edits[1] =#
    #= line_width += length(e) =#
    e = ""
    for (i, ei) in enumerate(edits)
        line_width += length(ei)
        @info (i, custom_indent, line_width, ei)
        if line_width > s.max_width
            e = merge_edits(e, ei, s; custom_indent=custom_indent)
            #= e = merge_edits(ei, e, s; custom_indent=custom_indent) =#
        else
            e = merge_edits(e, ei, s; join_lines=true)
            #= e = merge_edits(ei, e, s; join_lines=true) =#
        end
    end
    e
end

function pretty(x::CSTParser.WhereOpCall, s::State, custom_indent=0)
    line_offset = s.line_offset
    custom_indent += custom_indent == 0 ? line_offset : 0
    @info typeof(x), line_offset, custom_indent
    e1 = pretty(x.arg1, s, custom_indent)
    s.line_offset += 1
    e = merge_edits(e1, " " * pretty(x.op, s) * " ", s; join_lines=true)
    s.line_offset += 1
    merge_edits(e, pretty(x.args, s), s; join_lines=true)
end

function pretty(x::CSTParser.EXPR{CSTParser.Begin}, s::State, custom_indent=0)
    e = pretty(x.args[1], s)
    if length(x.args[2]) == 0
        e *= " "
        s.line_offset += 1
    else
        sl = cursor_loc(s)[1] == cursor_loc(s, s.offset+x.args[2].fullspan+x.args[3].span-1)[1]
        sl && x.args[2].fullspan != 0 && (e *= " "; s.line_offset += 1)
        s.indents += 1
        e = merge_edits(e, pretty(x.args[2], s, custom_indent), s)
        s.indents -= 1
    end
    merge_edits(e, pretty(x.args[3], s), s)
end

function pretty(x::CSTParser.EXPR{CSTParser.Quote}, s::State, custom_indent=0)
    if x.args[1] isa CSTParser.KEYWORD && x.args[1].kind == Tokens.QUOTE
        e = pretty(x.args[1], s, custom_indent)
        if length(x.args[2]) == 0
            e *= " "
            s.line_offset += 1
        else
            s.indents += 1
            e = merge_edits(e, pretty(x.args[2], s, custom_indent), s)
            s.indents -= 1
        end
        return merge_edits(e, pretty(x.args[3], s, custom_indent), s)
    end
    pretty(x.args, s, custom_indent)
end

function pretty(x::CSTParser.EXPR{CSTParser.Let}, s::State, custom_indent=0)
    e = ""
    if length(x.args) > 3
        e *= pretty(x.args[1], s) * " "
        s.line_offset += 1
        if x.args[2] isa CSTParser.EXPR{CSTParser.Block}
            e = merge_edits(e, pretty(x.args[2], s; ignore_single_line=true), s)
        else
            e = merge_edits(e, pretty(x.args[2], s), s)
        end
        if length(x.args[3]) == 0
            e *= " "
            s.line_offset += 1
        else
            s.indents += 1
            e = merge_edits(e, pretty(x.args[3], s, custom_indent), s)
            s.indents -= 1
        end
        e = merge_edits(e, pretty(x.args[4], s), s)
    else
        e = merge_edits(e, pretty(x.args[1], s), s)
        if length(x.args[2]) == 0
            e *= " "
            s.line_offset += 1
        else
            s.indents += 1
            e = merge_edits(e, pretty(x.args[2], s, custom_indent), s)
            s.indents -= 1
        end
        e = merge_edits(e, pretty(x.args[3], s), s)
    end
    e
end

function pretty(x::CSTParser.EXPR{CSTParser.If}, s::State, custom_indent=0)
    e = pretty(x.args[1], s)
    if x.args[1] isa CSTParser.KEYWORD && x.args[1].kind == Tokens.IF
        s.line_offset += 1
        e = merge_edits(e, " " * pretty(x.args[2], s), s)
        sl = cursor_loc(s)[1] == cursor_loc(s, s.offset+x.args[3].fullspan-1)[1]
        sl && x.args[3].fullspan != 0 && (e *= " "; s.line_offset += 1)
        s.indents += 1
        e = merge_edits(e, pretty(x.args[3], s, custom_indent), s)
        s.indents -= 1
        e = merge_edits(e, pretty(x.args[4], s), s)
        if length(x.args) > 4
            s.indents += 1
            e = merge_edits(e, pretty(x.args[5].args[1], s, custom_indent), s)
            s.indents -= 1
            e = merge_edits(e, pretty(x.args[6], s), s)
        end
    else
        e = merge_edits(e, pretty(x.args[2], s), s)
        if length(x.args) > 2
            s.indents -= 1
            e = merge_edits(e, pretty(x.args[3], s, custom_indent), s)
            s.indents += 1
            e = merge_edits(e, pretty(x.args[4], s), s)
        end
    end
    e
end

function pretty(x::CSTParser.EXPR{T}, s::State, custom_indent=0) where T <: Union{CSTParser.Comparison,CSTParser.ChainOpCall,CSTParser.Kw}
    e = ""
    for (i, a) in enumerate(x)
        ei = pretty(a, s)
        if a isa CSTParser.OPERATOR
            s.line_offset += 1
            e = merge_edits(e, " " * ei * " ", s; join_lines=true)
            s.line_offset += 1
        elseif i == length(x) - 1 && a isa CSTParser.PUNCTUATION && x.args[i+1] isa CSTParser.PUNCTUATION
            e = merge_edits(e, ei, s; join_lines=true)
        elseif a isa CSTParser.PUNCTUATION && a.kind == Tokens.COMMA && i != length(x)
            e = merge_edits(e, ei * " ", s; join_lines=true)
            s.line_offset += 1
        else
            e = merge_edits(e, ei, s; join_lines=true)
        end
    end
    e
end

function pretty(x::CSTParser.EXPR{CSTParser.Return}, s::State, custom_indent=0)
    e = pretty(x.args[1], s)
    if x.args[2].fullspan != 0
        s.line_offset += 1
        custom_indent += custom_indent == 0 ? s.line_offset : 0
        e = merge_edits(e, " " * pretty(x.args[2:end], s, custom_indent), s; join_lines=true)
    end
    e
end

function pretty(x::CSTParser.EXPR{CSTParser.Parameters}, s::State, custom_indent=0)
    line_offset = s.line_offset
    custom_indent += custom_indent == 0 ? line_offset : 0

    edits = Edit[]
    e = ""
    for (i, a) in enumerate(x)
        if CSTParser.is_comma(a)
            e = merge_edits(e, pretty(a, s, custom_indent) * " ", s; join_lines=true)
            push!(edits, e)
            e = ""
        else
            e = merge_edits(e,  pretty(a, s, custom_indent), s; join_lines=true)
        end
    end
    push!(edits, e)

    line_width = custom_indent == 0 ? line_offset : custom_indent
    # add 2 for "; "
    line_width += sum(length.(edits)) + 2
    @info "CUSTOM OFFSET", custom_indent
    @info "LINE WIDTH", line_width

    @info edits
    e = line_width > s.max_width ? ";" : "; "
    for (i, ei) in enumerate(edits)
        if line_width > s.max_width
            e = merge_edits(e, ei, s; custom_indent=custom_indent)
        else
            e = merge_edits(e, ei, s; join_lines=true)
        end
    end
    e
end

# ["mulm(", "a,", "b)"]
function pretty(x::CSTParser.EXPR{T}, s::State, custom_indent=0) where T <: Union{CSTParser.Curly,CSTParser.Call}
    line_offset = s.line_offset
    edits = Edit[pretty(x.args[1:2], s)]
    custom_indent += custom_indent == 0 ? line_offset + length(edits[1]) : length(edits[1])
    sep = x isa CSTParser.EXPR{CSTParser.Call} ? " " : ""

    @info "ENTERING CALL line_offset = $(line_offset), custom_indent = $(custom_indent)", edits[1].text

    e = ""
    for (i, a) in enumerate(x.args[3:end])
        if CSTParser.is_comma(a)
            # remove trailing comma
            i == length(x) - 3 && continue
            e = merge_edits(e, pretty(a, s, custom_indent) * sep, s; join_lines=true)
            s.line_offset += length(sep)
            push!(edits, e)
            e = ""
        else
            e = merge_edits(e, pretty(a, s, custom_indent), s; join_lines=true)
        end
    end
    push!(edits, e)

    line_width = custom_indent == 0 ? line_offset : custom_indent
    line_width += sum(length.(edits[2:end]))
    @info "CUSTOM OFFSET", custom_indent
    @info "LINE WIDTH", line_width

    e = ""
    for (i, ei) in enumerate(edits)
        @info i, line_width, length(ei), ei.text
        if line_width > s.max_width && i > 2
            e = merge_edits(e, ei, s; custom_indent=custom_indent)
            if i == length(edits)
                #= @info "HERE", ei.text =#
                #= @info s.line_offset =#
                comma = findlast(",", ei.text)
                if comma == nothing
                    s.line_offset += length(ei)
                else
                    s.line_offset += first(comma) - 1 + length(ei) - first(findlast(" ", ei.text)) - 1
                end
                #= @info s.line_offset =#
            end
        else
            e = merge_edits(e, ei, s; join_lines=true)
        end
    end

    # TODO: length of the edit could be way more
    #= s.line_offset += length(edits[end]) =#
    #= line_width > s.max_width && (s.line_offset += count(c -> c != ' ', edits[end].text)) =#
    #= line_width > s.max_width && (s.line_offset += ) =#
    #= line_width > s.max_width && (s.line_offset = ) =#
    @info s.line_offset
    @info "EXITING CALL line_offset = $(line_offset), custom_indent = $(custom_indent)", edits[1].text
    #= @info s.line_offset =#
    #= @info edits =#
    #= s.line_offset += count(c -> c != ' ', edits[end].text) =#
    #= @info "EXITING CALL", s.line_offset =#
    e
end

# Foo{T,V,S}
#= function pretty(x::CSTParser.EXPR{CSTParser.Curly}, s::State, custom_indent=0) =#
#=     line_offset = s.line_offset =#
#=     edits = Edit[pretty(x.args[1:2], s)] =#
#=     custom_indent += custom_indent == 0 ? line_offset + length(edits[1]) : length(edits[1]) =#
#=  =#
#=     @info "CURLY" =#
#=     @info edits[1].text, line_offset, custom_indent =#
#=  =#
#=     e = "" =#
#=     for (i, a) in enumerate(x.args[3:end]) =#
#=         e = merge_edits(e, pretty(a, s, custom_indent), s; join_lines=true) =#
#=         if CSTParser.is_comma(a) =#
#=             push!(edits, e) =#
#=             e = "" =#
#=         end =#
#=     end =#
#=     push!(edits, e) =#
#=  =#
#=     line_width = custom_indent == 0 ? line_offset : custom_indent =#
#=     line_width += sum(length.(edits[2:end])) =#
#=     @info "CUSTOM OFFSET", custom_indent =#
#=     @info "LINE WIDTH", line_width =#
#=  =#
#=     e = "" =#
#=     for (i, ei) in enumerate(edits) =#
#=         #= @info line_width, length(ei), ei.text =# =#
#=         if line_width > s.max_width && i > 2 =#
#=             e = merge_edits(e, ei, s; custom_indent=custom_indent) =#
#=         else =#
#=             e = merge_edits(e, ei, s; join_lines=true) =#
#=         end =#
#=     end =#
#=     e =#
#= end =#

function pretty(x::CSTParser.EXPR{T}, s::State, custom_indent=0) where T <: Union{CSTParser.TupleH,CSTParser.Vect}
    line_offset = s.line_offset
    custom_indent += custom_indent == 0 ? line_offset + 1 : 1

    @info typeof(x), custom_indent, line_offset

    e = ""
    edits = Edit[]
    for (i, a) in enumerate(x)
        if CSTParser.is_comma(a) && i != length(x) - 1
            e = merge_edits(e, pretty(a, s, custom_indent) * " ", s; join_lines=true)
            push!(edits, e)
            e = ""
        else
            e = merge_edits(e, pretty(a, s, custom_indent), s; join_lines=true)
        end
    end
    push!(edits, e)

    @info edits

    line_width = custom_indent == 0 ? line_offset : custom_indent

    e = ""
    for (i, ei) in enumerate(edits)
        @info line_width, length(ei), ei.text
        if line_width + length(ei) > s.max_width && i > 1
            e = merge_edits(e, ei, s; custom_indent=custom_indent)
            line_width = custom_indent
        else
            e = merge_edits(e, ei, s; join_lines=true)
        end
        line_width += length(ei)
    end
    e
end

function pretty(x::CSTParser.EXPR{T}, s::State, custom_indent=0) where T <: Union{CSTParser.Export,CSTParser.Import,CSTParser.Using}
    line_offset = s.line_offset
    custom_indent += custom_indent == 0 ? line_offset : 0

    @info typeof(x)

    e = pretty(x.args[1], s)
    si = 2
    if length(x) > 2 && CSTParser.is_colon(x.args[3])
        e = merge_edits(e, pretty(x.args[2], s), s; join_lines=true)
        e = merge_edits(e, pretty(x.args[3], s) * " ", s; join_lines=true)
        si = 4
    end
    custom_indent += length(e)

    @info "CI", custom_indent, line_offset

    edits = Edit[e]
    e = ""
    for (i, a) in enumerate(x.args[si:end])
        if CSTParser.is_comma(a)
            e = merge_edits(e, pretty(a, s, custom_indent) * " ", s; join_lines=true)
            push!(edits, e)
            e = ""
        else
            e = merge_edits(e, pretty(a, s, custom_indent), s; join_lines=true)
        end
    end
    @info edits

    line_width = line_offset

    e = ""
    for (i, ei) in enumerate(edits)
        line_width += length(ei)
        @info line_width, length(ei), ei.text
        if line_width > s.max_width && i > 2
            e = merge_edits(e, ei, s; custom_indent=custom_indent)
            line_width = custom_indent
        else
            e = merge_edits(e, ei, s; join_lines=true)
        end
        line_width += length(ei)
    end
    e
end

function format(text::AbstractString; indent_width=4, max_width=90)
    d = Document(text, newline_ranges(text))
    s = State(indent_width, max_width, 0, 1, 0, d)
    x = CSTParser.parse(text, true)
    e = pretty(x, s)::Edit
    if e.startline != 1
        e = merge_edits(Edit(1, 1, d.text[d.ranges[1]]), e, s)
    end
    if e.endline != length(d.ranges)
        e = merge_edits(e, Edit(length(d.ranges), length(d.ranges), d.text[d.ranges[end]]), s)
    end
    e.text
end
