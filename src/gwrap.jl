
const gtype_abstracts = Dict{Symbol,Type}()
const gtype_wrappers = Dict{Symbol,Type}()
const gtype_ifaces = Dict{Symbol,Type}()

gtype_abstracts[:GObject] = GObject
gtype_wrappers[:GObject] = GObjectLeaf

let libs = Dict{String,Any}()
global get_fn_ptr
function get_fn_ptr(fnname, lib)
    if !isa(lib,String)
        lib = eval(current_module(), lib)
    end
    libptr = get(libs, lib, C_NULL)::Ptr{Void}
    if libptr == C_NULL
        libs[lib] = libptr = dlopen(lib)
    end
    fnptr = dlsym_e(libptr, fnname)
end
end
function g_type(name::Symbol, lib, symname::Symbol)
    if name in keys(gtype_wrappers)
        return g_type(gtype_wrappers[name])
    end
    fnptr = get_fn_ptr(string(symname,"_get_type"), lib)
    if fnptr != C_NULL
        ccall(fnptr, GType, ())
    else
        convert(GType, 0)
    end
end
g_type(name::Symbol, lib, symname::Expr) = eval(current_module(), symname)

function get_interface_decl(iname::Symbol, gtyp::GType, gtyp_decl)
    if isdefined(current_module(), iname)
        return nothing
    end
    parent = g_type_parent(gtyp)
    @assert parent != 0
    piname = g_type_name(parent)
    quote
        if $(QuoteNode(iname)) in keys(gtype_ifaces)
            const $(esc(iname)) = gtype_abstracts[$(Meta.quot(iname))]
        else
            immutable $(esc(iname)) <: GInterface
                handle::Ptr{GObject}
                gc::Any
                $(esc(iname))(x::GObject) = new(convert(Ptr{GObject},x), x)
                # Gtk does an interface type check when calling methods. So, it's
                # not worth repeating it here. Plus, we might as well just allow
                # the user to lie, since we aren't using this for dispatch
                # (like C & unlike most other languages), the user may be able 
                # to write more generic code
            end
            gtype_ifaces[$(QuoteNode(iname))] = $(esc(iname))
            $gtyp_decl
        end
        nothing
    end
end

function get_itype_decl(iname::Symbol, gtyp::GType)
    if isdefined(current_module(), iname)
        return nothing
    end
    if iname === :GObject
        return :( const $(esc(iname)) = gtype_abstracts[:GObject] )
    end
    #ntypes = mutable(Cuint)
    #interfaces = ccall((:g_type_interfaces,libgobject),Ptr{GType},(GType,Ptr{Cuint}),gtyp,ntypes)
    #for i = 1:ntypes[]
    #    interface = unsafe_load(interfaces,i)
    #    # what do we care to do here?!
    #end
    #c_free(interfaces)
    parent = g_type_parent(gtyp)
    @assert parent != 0
    piname = g_type_name(parent)
    piface_decl = get_itype_decl(piname, parent)
    quote
        if $(QuoteNode(iname)) in keys(gtype_abstracts)
            const $(esc(iname)) = gtype_abstracts[$(QuoteNode(iname))]
        else
            $piface_decl
            abstract $(esc(iname)) <: $(esc(piname))
            gtype_abstracts[$(QuoteNode(iname))] = $(esc(iname))
        end
        nothing
    end
end

get_gtype_decl(name::Symbol, lib, symname::Expr) =
    :( GLib.g_type(::Type{$(esc(name))}) = $(esc(symname)) )
get_gtype_decl(name::Symbol, lib, symname::Symbol) =
    :( GLib.g_type(::Type{$(esc(name))}) =
        ccall(($(QuoteNode(symbol(string(symname,"_get_type")))), $(esc(lib))), GType, ()) )

function get_type_decl(name,iname,gtyp,gtype_decl)
    ename = esc(name)
    einame = esc(iname)
    quote
        if $(QuoteNode(iname)) in keys(gtype_wrappers)
            const $einame = gtype_abstracts[$(QuoteNode(iname))]
        else
            $(get_itype_decl(iname, gtyp))
        end
        type $ename <: $einame
            handle::Ptr{GObject}
            function $ename(handle::Ptr{GObject})
                if handle == C_NULL
                    error($("Cannot construct $name with a NULL pointer"))
                end
                gc_ref(new(handle))
            end
        end
        function $ename(args...; kwargs...)
            if isempty(kwargs)
                error(MethodError($ename, args))
            end
            w = $ename(args...)
            for (kw,val) in kwargs
                setproperty!(w, kw, val)
            end
            w
        end
        gtype_wrappers[$(QuoteNode(iname))] = $ename
        macro $einame(args...)
            Expr(:call, $ename, map(esc,args)...)
        end
        $gtype_decl
        nothing
    end
end

macro Gtype_decl(name,gtyp,gtype_decl)
    get_type_decl(name,symbol(string(name,current_module().suffix)),gtyp,gtype_decl)
end

macro Gtype(iname,lib,symname)
    gtyp = g_type(iname, lib, symname)
    if gtyp == 0
        return Expr(:call,:error,string("Could not find ",symname," in ",lib,
            ". This is likely a issue with a missing Gtk.jl version check."))
    end
    @assert iname === g_type_name(gtyp)
    if !g_type_test_flags(gtyp, G_TYPE_FLAG_CLASSED)
        error("GType is currently only implemented for G_TYPE_FLAG_CLASSED")
    end
    name = symbol(string(iname,current_module().suffix))
    gtype_decl = get_gtype_decl(name, lib, symname)
    get_type_decl(name, iname, gtyp, gtype_decl)
end

macro Gabstract(iname,lib,symname)
    gtyp = g_type(iname, lib, symname)
    if gtyp == 0
        return Expr(:call,:error,string("Could not find ",symname," in ",lib,". This is likely a issue with a missing Gtk.jl version check."))
    end
    @assert iname === g_type_name(gtyp)
    Expr(:block,
        get_itype_decl(iname, gtyp),
        get_gtype_decl(iname, lib, symname))
end

macro Giface(iname,lib,symname)
    gtyp = g_type(iname, lib, symname)
    if gtyp == 0
        return Expr(:call,:error,string("Could not find ",symname," in ",lib,". This is likely a issue with a missing Gtk.jl version check."))
    end
    @assert iname === g_type_name(gtyp)
    gtype_decl = get_gtype_decl(iname, lib, symname)
    get_interface_decl(iname::Symbol, gtyp::GType, gtype_decl)
end

# this could be used for gtk methods returing widgets of unknown type
# and/or might have been wrapped by julia before
function convert{T<:GObject}(::Type{T}, hnd::Ptr{GObject})
    if hnd == C_NULL
        error("cannot convert null pointer to GObject")
    end
    x = ccall((:g_object_get_qdata, libgobject), Ptr{GObject}, (Ptr{GObject},Uint32), hnd, jlref_quark)
    if x != C_NULL
        return unsafe_pointer_to_objref(x)::T
    end
    wrap_gobject(hnd)::T
end

function wrap_gobject(hnd::Ptr{GObject})
    gtyp = G_OBJECT_CLASS_TYPE(hnd)
    typname = g_type_name(gtyp)
    while !(typname in keys(gtype_wrappers))
        gtyp = g_type_parent(gtyp)
        @assert gtyp != 0
        typname = g_type_name(gtyp)
    end
    T = gtype_wrappers[typname]
    return T(hnd)
end

