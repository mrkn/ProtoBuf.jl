const JULIA_RESERVED_KEYWORDS = Set{String}([
    "baremodule", "begin", "break", "catch", "const", "continue", "do", "else", "elseif", "end",
    "export", "false", "finally", "for", "function", "global", "if", "import", "let", "local",
    "macro", "module", "quote", "return", "struct", "true", "try", "using", "while",
    "abstract", "ccall", "typealias", "type", "bitstype", "importall", "immutable", "Type", "Enum",
    "Any", "DataType", "Base", "Core", "InteractiveUtils", "Set", "Method", "include", "eval", "ans",
    # TODO: add all subtypes(Any) from a fresh julia session?
    "OneOf",
])

function try_strip_namespace(name::AbstractString, imports::Set{String})
    for _import in imports
        if startswith(name, "$(_import).")
            return @view name[nextind(name, length(_import), 2):end]
        end
    end
    return name
end

function safename(name::AbstractString, imports::Set{String})
    for _import in imports
        if startswith(name, "$(_import).")
            namespaced_name = @view name[nextind(name, length(_import), 2):end]
            return string(proto_module_name(_import), '.', safename(namespaced_name))
        end
    end
    safename(name)
end

function safename(name::AbstractString)
    # TODO: handle namespaced definitions (pkg_name.MessageType)
    dot_pos = findfirst(==('.'), name)
    if name in JULIA_RESERVED_KEYWORDS
        return string("var\"#", name, '"')
    elseif isnothing(dot_pos) && !('#' in name)
        return name
    elseif dot_pos == 1
        return string("@__MODULE__.", safename(@view name[2:end]))
    else
        return string("var\"", name, '"')
    end
end

# function translate_import_path(p::ResolvedProtoFile)
#     assumed_file_relpath = joinpath(replace(p.preamble.namespace, '.' => '/'), "")
#     relpaths = String[]
#     for i in p.proto_file.preamble.file_map
#         rel_path_to_module = relpath(dirname(i.path), assumed_file_relpath)
#         translated_module_name = proto_module_name(i.path)
#         push!(relpaths, joinpath(rel_path_to_module, translated_module_name))
#     end
#     return relpaths
# end

codegen(t::Parsers.AbstractProtoType, p::ProtoFile, file_map, imports) = codegen(stdin, t, p, file_map, imports)

_is_repeated_field(f::Parsers.AbstractProtoFieldType) = f.label == Parsers.REPEATED
_is_repeated_field(::Parsers.OneOfType) = false

function codegen(io, t::Parsers.MessageType, p::ProtoFile, file_map, imports)
    print(io, "struct ", safename(t.name), length(t.fields) > 0 ? "" : ' ')
    length(t.fields) > 0 && println(io)
    for field in t.fields
        if _is_repeated_field(field)
            println(io, "    ", jl_fieldname(field), "::Vector{", jltypename(field, p, file_map, imports), '}')
        else
            println(io, "    ", jl_fieldname(field), "::", jltypename(field, p, file_map, imports))
        end
    end
    println(io, "end")
end

codegen(io, t::Parsers.GroupType, p::ProtoFile, file_map, imports) = codegen(io, t.type, p, file_map, imports)

function codegen(io, t::Parsers.EnumType, ::ProtoFile, file_map, imports)
    name = safename(t.name)
    println(io, "@enumx ", name, join(" $k=$n" for (k, n) in zip(keys(t.elements), t.elements)))
end

function codegen(io, t::Parsers.ServiceType, ::ProtoFile, file_map, imports)
    println(io, "# TODO: SERVICE")
    println(io, "#    ", t)
end

jl_fieldname(f::Parsers.AbstractProtoFieldType) = safename(f.name)
jl_fieldname(f::Parsers.GroupType) = f.field_name

jltypename(f::Parsers.AbstractProtoFieldType, p, file_map, imports)  = jltypename(f.type, p, file_map, imports)

jltypename(::Parsers.DoubleType, p, file_map, imports)      = "Float64"
jltypename(::Parsers.FloatType, p, file_map, imports)       = "Float32"
jltypename(::Parsers.Int32Type, p, file_map, imports)       = "Int32"
jltypename(::Parsers.Int64Type, p, file_map, imports)       = "Int64"
jltypename(::Parsers.UInt32Type, p, file_map, imports)      = "UInt32"
jltypename(::Parsers.UInt64Type, p, file_map, imports)      = "UInt64"
jltypename(::Parsers.SInt32Type, p, file_map, imports)      = "Int32"
jltypename(::Parsers.SInt64Type, p, file_map, imports)      = "Int64"
jltypename(::Parsers.Fixed32Type, p, file_map, imports)     = "UInt32"
jltypename(::Parsers.Fixed64Type, p, file_map, imports)     = "UInt64"
jltypename(::Parsers.SFixed32Type, p, file_map, imports)    = "Int32"
jltypename(::Parsers.SFixed64Type, p, file_map, imports)    = "Int64"
jltypename(::Parsers.BoolType, p, file_map, imports)        = "Bool"
jltypename(::Parsers.StringType, p, file_map, imports)      = "String"
jltypename(::Parsers.BytesType, p, file_map, imports)       = "Vector{UInt8}"
jltypename(t::Parsers.MessageType, p, file_map, imports)    = safename(t.name, imports)
jltypename(t::Parsers.MapType, p, file_map, imports)        = string("Dict{", jltypename(t.keytype,p,file_map,imports), ',', jltypename(t.valuetype,p,file_map,imports), "}")
function jltypename(t::Parsers.ReferencedType, p, file_map, imports)
    name = safename(t.name, imports)
    # This is where EnumX.jl bites us -- we need to search through all defitnition (including imported)
    # to make sure a ReferencedType is an Enum, in which case we need to add a `.T` suffix.
    isa(get(p.definitions, t.name, nothing), Parsers.EnumType) && return string(name, ".T")
    lookup_name = try_strip_namespace(t.name, imports)
    for path in import_paths(p)
        defs = file_map[path].proto_file.definitions
        @info t.name name defs
        isa(get(defs, lookup_name, nothing), Parsers.EnumType) && return string(name, ".T")
    end
    return name
end
# TODO: Allow (via options?) to be the parent struct parametrized on the type of OneOf
#       Parent structs should be then be parametrized as well?
function jltypename(t::Parsers.OneOfType, p, file_map, imports)
    union_types = unique!([jltypename(f.type, p, file_map, imports) for f in t.fields])
    if length(union_types) > 1
        return string("OneOf{Union{", join(union_types, ','), "}}")
    else
        return string("OneOf{", only(union_types), "}")
    end
end

function translate(path::String, rp::ResolvedProtoFile, file_map::Dict{String,ResolvedProtoFile})
    open(path, "w") do io
        translate(io, rp, file_map)
    end
end

translate(rp::ResolvedProtoFile, file_map::Dict{String,ResolvedProtoFile}) = translate(stdin, rp, file_map)
function translate(io, rp::ResolvedProtoFile, file_map::Dict{String,ResolvedProtoFile})
    pkg_metadata = Pkg.project()
    p = rp.proto_file
    imports = Set{String}(Iterators.map(i->namespace(file_map[i]), import_paths(p)))
    println(io, "# Autogenerated using $(pkg_metadata.name).jl v$(pkg_metadata.version) on $(Dates.now())")
    println(io, "# original file: ", p.filepath," (proto", p.preamble.isproto3 ? '3' : '2', " syntax)")
    println(io)

    if !is_namespaced(p)
        # if current file is not namespaced, it will not live in a module
        # and will need to import its dependencies directly.
        for path in import_paths(p)
            dependency = file_map[path]
            if !is_namespaced(dependency)
                # if the dependency is also not namespaced, we can just include it
                println(io, "include(", repr(proto_script_name(dependency)), ")")
            else
                # otherwise we need to import it trough a module
                println(io, "include(", repr(proto_module_name(dependency)), ")")
                println(io, "using ", proto_module_name(dependency))
            end
        end
    end # Otherwise all includes will happen in the enclosing module
    println(io, "using ProtocolBuffers: OneOf")
    println(io, "using EnumX: @enumx")
    if is_namespaced(p)
        println(io)
        println(io, "export ", join(Iterators.map(x->safename(x, imports), keys(p.definitions)), ", "))
    end
    println(io)
    for def_name in p.sorted_definitions
        println(io)
        codegen(io, p.definitions[def_name], p, file_map, imports)
    end
end