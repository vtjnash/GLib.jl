module GLib

import Base: convert, show, showall, showcompact, size, length, getindex, setindex!,
             start, next, done, eltype

export GInterface, GType, GObject, GBoxed, @Gtype, @Gabstract, @Giface
export Enum, GError, GValue, gvalue, make_gvalue, g_type
export GList, glist_iter, _GSList, _GList, gc_ref, gc_unref, gc_move_ref, gc_ref_closure
export signal_connect, signal_emit, signal_handler_disconnect
export signal_handler_block, signal_handler_unblock
export setproperty!, getproperty

include(joinpath("..","deps","ext.jl"))

# local function, handles Symbol and makes UTF8-strings easier
typealias StringLike Union(String,Symbol)
bytestring(s) = Base.bytestring(s)
bytestring(s::Symbol) = s
bytestring(s::Ptr{Uint8},own::Bool) = UTF8String(pointer_to_array(s,int(ccall(:strlen,Csize_t,(Ptr{Uint8},),s)),own))

function concrete_subtypes(T::DataType...)
    queue = [T...]
    subt = Set{DataType}()
    while !isempty(queue)
        x = pop!(queue)
        if isa(x,DataType)
            if x.abstract
                for s in Base.subtypes(x)
                    push!(queue, s)
                end
            else
                push!(subt, x)
            end
        end
    end
    return subt
end

ccall((:g_type_init,libgobject),Void,())

include("MutableTypes.jl")
using .MutableTypes

include("glist.jl")
include("gtype.jl")
include("gwrap.jl")
include("gvalues.jl")
include("gerror.jl")
include("gsignals.jl")

export @g_type_delegate
macro g_type_delegate(eq)
    @assert isa(eq,Expr) && eq.head == :(=) && length(eq.args) == 2
    new = eq.args[1]
    real = eq.args[2]
    newleaf = esc(symbol(string(new,current_module().suffix)))
    realleaf = esc(symbol(string(real,current_module().suffix)))
    new = esc(new)
    macroreal = QuoteNode(symbol(string('@',real)))
    quote
        const $newleaf = $realleaf
        macro $new(args...)
            Expr(:macrocall, $macroreal, map(esc,args)...)
        end
    end
end

end # module
