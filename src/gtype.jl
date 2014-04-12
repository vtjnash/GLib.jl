abstract GObject
abstract GInterface <: GObject
abstract GBoxed

typealias Enum Int32
typealias GType Csize_t
immutable GParamSpec
  g_type_instance::Ptr{Void}
  name::Ptr{Uint8}
  flags::Cint
  value_type::GType
  owner_type::GType
end

const fundamental_types = (
    #(:name,      Ctype,            JuliaType,      g_value_fn)
    (:invalid,    Void,             Void,           :error),
    (:void,       Nothing,          Nothing,        :error),
    (:GInterface, Ptr{Void},        GInterface,     :error),
    (:gchar,      Int8,             Int8,           :schar),
    (:guchar,     Uint8,            Uint8,          :uchar),
    (:gboolean,   Cint,             Bool,           :boolean),
    (:gint,       Cint,             None,           :int),
    (:guint,      Cuint,            None,           :uint),
    (:glong,      Clong,            None,           :long),
    (:gulong,     Culong,           None,           :ulong),
    (:gint64,     Int64,            Signed,         :int64),
    (:guint64,    Uint64,           Unsigned,       :uint64),
    (:GEnum,      Enum,             None,           :enum),
    (:GFlags,     Enum,             None,           :flags),
    (:gfloat,     Float32,          Float32,        :float),
    (:gdouble,    Float64,          FloatingPoint,  :double),
    (:gchararray, Ptr{Uint8},       String,         :string),
    (:gpointer,   Ptr{Void},        Ptr,            :pointer),
    (:GBoxed,     Ptr{Void},        GBoxed,         :boxed),
    (:GParam,     Ptr{GParamSpec},  Ptr{GParamSpec},:param),
    (:GObject,    Ptr{GObject},     GObject,        :object),
    #(:GVariant,  Ptr{GVariant},    GVariant,       :variant),
    )
# NOTE: in general do not cache ids, except for these fundamental values
g_type_from_name(name::Symbol) = ccall((:g_type_from_name,libgobject),GType,(Ptr{Uint8},),name)
const fundamental_ids = tuple(GType[g_type_from_name(name) for (name,c,j,f) in fundamental_types]...)
# this constant is needed elsewhere, but doesn't have a matching Julia type so it can't be used from g_type
const gboxed_id = g_type_from_name(:GBoxed)

g_type(gtyp::GType) = gtyp
let jtypes = Expr(:block, :( g_type(::Type{Void}) = $(g_type_from_name(:void)) ))
    for (i,(name, ctype, juliatype, g_value_fn)) in enumerate(fundamental_types)
        if juliatype !== None
            push!(jtypes.args, :( g_type{T<:$juliatype}(::Type{T}) = convert(GType,$(fundamental_ids[i])) ))
        end
    end
    eval(jtypes)
end

G_TYPE_FROM_CLASS(w::Ptr{Void}) = unsafe_load(convert(Ptr{GType},w))
G_OBJECT_GET_CLASS(w::GObject) = G_OBJECT_GET_CLASS(w.handle)
G_OBJECT_GET_CLASS(hnd::Ptr{GObject}) = unsafe_load(convert(Ptr{Ptr{Void}},hnd))
G_OBJECT_CLASS_TYPE(w) = G_TYPE_FROM_CLASS(G_OBJECT_GET_CLASS(w))

g_isa(gtyp::GType, is_a_type::GType) = bool(ccall((:g_type_is_a,libgobject),Cint,(GType,GType),gtyp,is_a_type))
g_type_parent(child::GType) = ccall((:g_type_parent, libgobject), GType, (GType,), child)
g_type_name(g_type::GType) = symbol(bytestring(ccall((:g_type_name,libgobject),Ptr{Uint8},(GType,),g_type),false))

g_type_test_flags(g_type::GType, flag) = ccall((:g_type_test_flags,libgobject), Bool, (GType,Enum), g_type, flag)
const G_TYPE_FLAG_CLASSED           = 1 << 0
const G_TYPE_FLAG_INSTANTIATABLE    = 1 << 1
const G_TYPE_FLAG_DERIVABLE         = 1 << 2
const G_TYPE_FLAG_DEEP_DERIVABLE    = 1 << 3
type GObjectLeaf <: GObject
    handle::Ptr{GObject}
    function GObjectLeaf(handle::Ptr{GObject})
        if handle == C_NULL
            error("Cannot construct $gname with a NULL pointer")
        end
        gc_ref(new(handle))
    end
end
g_type(obj::GObject) = g_type(typeof(obj))

gtypes(types...) = GType[g_type(t) for t in types]

macro quark_str(q)
    :( ccall((:g_quark_from_string, libglib), Uint32, (Ptr{Uint8},), bytestring($q)) )
end
const jlref_quark = quark"julia_ref"

# All GObjects are expected to have a 'handle' field
# of type Ptr{GObject} corresponding to the GLib object
convert(::Type{Ptr{GObject}},w::GObject) = w.handle
convert{T<:GObject}(::Type{T},w::Ptr{T}) = convert(T,convert(Ptr{GObject},w))
eltype{T<:GObject}(::_LList{T}) = T

convert{T<:GBoxed}(::Type{Ptr{T}},box::T) = box.handle
convert{T<:GBoxed}(::Type{T},unbox::Ptr{T}) = T(unbox)

### Garbage collection [prevention]
const gc_preserve = ObjectIdDict() # reference counted closures
function gc_ref(x::ANY)
    global gc_preserve
    gc_preserve[x] = (get(gc_preserve, x, 0)::Int)+1
    x
end
function gc_unref(x::ANY)
    global gc_preserve
    count = get(gc_preserve, x, 0)::Int-1
    if count <= 0
        delete!(gc_preserve, x)
    end
    nothing
end
gc_ref_closure{T}(x::T) = (gc_ref(x);cfunction(gc_unref, Void, (T, Ptr{Void})))
gc_unref(x::Any, ::Ptr{Void}) = gc_unref(x)

const gc_preserve_gtk = WeakKeyDict{GObject,Union(Bool,GObject)}() # gtk objects
function gc_ref{T<:GObject}(x::T)
    global gc_preserve_gtk
    addref = function()
        ccall((:g_object_ref_sink,libgobject),Ptr{GObject},(Ptr{GObject},),x)
        finalizer(x,function(x)
                global gc_preserve_gtk
                if x.handle != C_NULL
                    gc_preserve_gtk[x] = x # convert to a strong-reference
                    ccall((:g_object_unref,libgobject),Void,(Ptr{GObject},),x) # may clear the strong reference
                else
                    delete!(gc_preserve_gtk, x) # x is invalid, ensure we are dead
                end
            end)
        gc_preserve_gtk[x] = true # record the existence of the object, but allow the finalizer
    end
    ref = get(gc_preserve_gtk,x,nothing)
    if isa(ref,Nothing)
        ccall((:g_object_set_qdata_full, libgobject), Void,
            (Ptr{GObject}, Uint32, Any, Ptr{Void}), x, jlref_quark, x,
            cfunction(gc_unref, Void, (T,))) # add a circular reference to the Julia object in the GObject
        addref()
    elseif !isa(ref,WeakRef)
        # oops, we previously deleted the link, but now it's back
        addref()
    else
        # already gc-protected, nothing to do
    end
    x
end

function gc_unref_weak(x::GObject)
    # this strongly destroys and invalidates the object
    # it is intended to be called by GLib, not in user code function
    # note: this may be called multiple times by GLib
    x.handle = C_NULL
    global gc_preserve_gtk
    delete!(gc_preserve_gtk, x)
    nothing
end
function gc_unref(x::GObject)
    # this strongly destroys and invalidates the object
    # it is intended to be called by GLib, not in user code function
    ref = ccall((:g_object_get_qdata,libgobject),Ptr{Void},(Ptr{GObject},Uint32),x,jlref_quark)
    if ref != C_NULL && x !== unsafe_pointer_to_objref(ref)
        # We got called because we are no longer the default object for this handle, but we are still alive
        warn("Duplicate Julia object creation detected for GObject")
        ccall((:g_object_weak_ref,libgobject),Void,(Ptr{GObject},Ptr{Void},Any),x,cfunction(gc_unref_weak,Void,(typeof(x),)),x)
    else
        ccall((:g_object_steal_qdata,libgobject),Any,(Ptr{GObject},Uint32),x,jlref_quark)
        gc_unref_weak(x)
    end
    nothing
end
gc_unref(::Ptr{GObject}, x::GObject) = gc_unref(x)
gc_ref_closure(x::GObject) = C_NULL

function gc_force_floating(x::GObject)
    ccall((:g_object_force_floating,libgobject),Void,(Ptr{GObject},),x)
end
function gc_move_ref(new::GObject, old::GObject)
    @assert old.handle == new.handle != C_NULL
    gc_unref(old)
    gc_force_floating(new)
    gc_ref(new)
end
