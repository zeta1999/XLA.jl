function Base.:*(A::XRTArray, B::XRTArray)
    ddots = DimNums((1,), (0,), (), ())
    HloDot(ddots)(A, B)
end

function Base.:*(A::XRTArray, B::XRTVector)
    ddots = DimNums((1,), (0,), (), ())
    HloDot(ddots)(A, B)
end

# A couple of scalar embeddings (could use casette in the future)
Base.:+(A::XRTArray{T, (), 0}, B::XRTArray{T, (), 0}) where {T<:XLAScalar} =
    GenericHloOp{:add}(T, ())(A, B)
Base.:-(A::XRTArray{T, (), 0}, B::XRTArray{T, (), 0}) where {T<:XLAScalar} =
    GenericHloOp{:subtract}(T, ())(A, B)
Base.:/(A::XRTArray{T, (), 0}, B::XRTArray{T, (), 0}) where {T<:XLAScalar} =
    GenericHloOp{:divide}(T, ())(A, B)
Base.:*(A::XRTArray{T, (), 0}, B::XRTArray{T, (), 0}) where {T<:XLAScalar} =
    GenericHloOp{:multiply}(T, ())(A, B)
Base.zero(A::Type{XRTArray{T, (), 0}}) where T = XRTArray(zero(T))
Base.zero(A::XRTArray{<:Any, (), 0}) = zero(typeof(A))
Base.one(A::Type{XRTArray{T, (), 0}}) where T = XRTArray(one(T))
Base.one(A::XRTArray{<:Any, (), 0}) = one(typeof(A))
Base.max(A::XRTArray{T, (), 0}, B::XRTArray{T, (), 0}) where {T<:XLAScalar} =
    GenericHloOp{:maximum}(T, ())(A, B)
Base.exp(A::XRTArray{T, (), 0}) where {T} = GenericHloOp{:exponential}(T, ())(A)

Base.transpose(A::XRTArray) = HloTranspose((1,0))(A)
Base.permutedims(A::XRTArray, perm) = HloTranspose(map(x->x-1, perm))(A)

import Base.Broadcast

Base.similar(x::XRTArray) = error()

struct XRTArrayStyle{N} <: Broadcast.AbstractArrayStyle{N} end
(::Type{<:XRTArrayStyle})(::Val{N}) where {N} = XRTArrayStyle{N}()
Broadcast.BroadcastStyle(::Type{<:XRTArray{<:Any,Dims,N}}) where {Dims, N} =
    XRTArrayStyle{N}()

@noinline _ccdims(s) = tuple(findall(==(1), s)...)
@noinline _ncdims(s) = tuple(findall(x->x!=(1), s)...)

@Base.pure ccdims(s) = _ccdims(s)
@Base.pure ncdims(s) = _ncdims(s)

@Base.pure getindex_tuple(s::Tuple, k::Tuple) = s[collect(k)]

@inline function broadcast_to_size(arg, rsize)
    if size(arg) != rsize
        collapse_dims = ccdims(size(arg))
        non_collapse_dims = ncdims(size(arg))
        if !isa(arg, XRTArray)
            arg = XRTArray(fill(arg))
        end
        if collapse_dims != ()
            arg = HloReshape(
                getindex_tuple(size(arg), non_collapse_dims)
            )(arg)
        end
        return HloBroadcast(map(x->x - 1, non_collapse_dims), rsize)(
            arg
        )
    else
        return arg
    end
end

# TODO: This should probably assert that the sessions are equivalent
any_sess(a::XRTArray, args::AnyXLA...) = a.storage.sess
any_sess(a::XLAScalar, args::AnyXLA...) = any_sess(args...)

function Broadcast.copy(bc::Broadcast.Broadcasted{<:XRTArrayStyle})
    ElType = Broadcast.combine_eltypes(bc.f, bc.args)
    bc′ = Broadcast.flatten(bc)
    if Base.isconcretetype(ElType)
        args = bc′.args
        # This could be axes(bc′) if we had better constant prop
        rsize = map(length, Broadcast.combine_axes(bc′.args...))
        args = map(arg->broadcast_to_size(arg, rsize), bc′.args)
        return HloMap{typeof(bc′.f)}()(bc′.f, args...)
    end
    # TODO: Pull back CPU, do this there
    error("No hope")
end

using NNlib

@Base.pure function conv_windows(sz_, pad_, stride_, dilation_)
    ntuple(length(pad_)) do i
        (sz, p, s, d) = sz_[i], pad_[i], stride_[i], dilation_[i]
        WindowDims(sz, s, p, p, d, 1, true)
    end
end

function NNlib.conv(input::XRTArray, kernel::XRTArray; pad = 0, stride = 1, dilation = 1)
    pad_, stride_ = NNlib.padtuple(input, pad), NNlib.padtuple(input, stride)
    dilation_ = NNlib.padtuple(kernel, dilation)
    sz_ = size(kernel)
    windows = conv_windows(sz_, pad_, stride_, dilation_)
    convdims = ConvDimNums(
        3, 2, (0, 1),
        2, 3, (0, 1),
        3, 2, (0, 1)
    )
    HloConv(windows, convdims)(input, kernel)
end

function NNlib.∇conv_data(dy::XRTArray, input::XRTArray, kernel::XRTArray; pad = 0, stride = 1, dilation = 1)
    pad_, stride_ = NNlib.padtuple(input, pad), NNlib.padtuple(input, stride)
    dilation_ = NNlib.padtuple(kernel, dilation)
    mirrored = kernel #permutedims(kernel, (2, 1, 3, 4)) #HloRev((0,1))(kernel)
    sz_ = size(kernel); isz = size(input); osz = size(dy)
    windows = ntuple(length(pad_)) do i
        (sz, p, s, d) = sz_[i], pad_[i], stride_[i], dilation_[i]
        @assert s == 1
        @assert d == 1
        padded_out_size = isz[i] + sz - 1
        pad_before = sz - 1 - p
        pad_after = padded_out_size - osz[i] - pad_before
        # N.B.: The window reversal flag is flipped here
        WindowDims(sz, s, pad_before, pad_after, d, 1, false)
    end
    convdims = ConvDimNums(
        3, 2, (0, 1),
        # N.B. The input and output dimensions are exchanged here from the
        # standard notion of convolution
        3, 2, (0, 1),
        3, 2, (0, 1)
    )
    HloConv(windows, convdims)(dy, mirrored)
end

function NNlib.∇conv_filter(dy::XRTArray, input::XRTArray, kernel::XRTArray; pad = 0, stride = 1, dilation = 1)
    # TODO: Validate that this is correct. Unfortunately, the NNlib
    # implementation itself is broken, so we need to fix that first
    pad_, stride_ = NNlib.padtuple(input, pad), NNlib.padtuple(input, stride)
    dilation_ = NNlib.padtuple(kernel, dilation)
    sz_ = size(kernel); isz = size(input); osz = size(dy)
    input = HloRev((0,1))(input)
    windows = ntuple(length(pad_)) do i
        (sz, p, s, d) = sz_[i], pad_[i], stride_[i], dilation_[i]
        @assert s == 1
        @assert d == 1
        padded_in_size = osz[i] + sz - 1
        pad_total = padded_in_size - isz[i]
        pad_before = max(div(pad_total, 2), 0)
        pad_after = pad_total - pad_before
        WindowDims(osz[i], s, pad_before, pad_after, d, 1, false)
    end
    convdims = ConvDimNums(
        3, 2, (0, 1),
        2, 3, (0, 1),
        3, 2, (0, 1)
    )
    HloConv(windows, convdims)(input, dy)
end


function make_maxpool_windows(x, k, pad, stride)
    k_, pad_, stride_ = NNlib.padtuple(x, k),
                        NNlib.padtuple(x, pad),
                        NNlib.padtuple(x, stride)
    windows = ntuple(ndims(x)) do i
        (sz, p, s) = i <= length(k) ? (k[i], pad[i], stride[i]) : (1, 0, 1)
        WindowDims(sz, s, p, p, 1, 1, false)
    end
end

function NNlib.maxpool(x::XRTArray, k; pad = map(_->0,k), stride = k)
    HloReduceWindow{typeof(max)}(
        make_maxpool_windows(x, k, pad, stride)
    )(max, x, XRTArray(typemin(eltype(x))))
end

function NNlib.∇maxpool(dy::XRTArray, y::XRTArray, x::XRTArray, k; pad = map(_->0,k), stride = k)
    HloSelectAndScatter2(
        >=, +,
        make_maxpool_windows(x, k, pad, stride)
    )(x, dy, XRTArray(zero(eltype(x))))
end

function NNlib.softmax(xs::XRTArray)
    ys = xs .- maximum(xs)
    exp.(ys) ./ sum(exp.(ys))
end
function NNlib.∇softmax(Δ, xs::XRTArray)
    s = sum(exp, xs, dims=1)
    exp.(xs)./s.*(Δ .- sum(Δ .* exp.(xs), dims=1)./s)
end

@Base.pure dims_tuple(n) = tuple((0:n-1)...)
@Base.pure rev_dims_tuple(n) = tuple((n-1:-1:0)...)
dims_tuple(A, ::Colon) = dims_tuple(ndims(A))
dims_tuple(A, t::Tuple) = map(x->x-1, t)
dims_tuple(A, n::Int) = (n-1,)

@inline function Base.reshape(A::XRTArray, dims::Tuple{Vararg{Union{Int,Colon}}})
    reshape(A, Base._reshape_uncolon(A, dims))
end

@inline function Base.reshape(A::XRTArray, dims::Tuple{Vararg{Int}})
    prod(dims) == prod(size(A)) || Base._throw_dmrsa(dims, prod(size(A)))
    HloReshape(dims)(
        # HLO reshape semantics collapse the opposite way
        HloTranspose(rev_dims_tuple(ndims(A)))(A)
    )
end

@Base.pure reduced_dimensions_collapes(sz, dims) = ntuple(i->i in dims ? 1 : sz[i], length(sz))
function Base.mapreduce(f, op, A::XRTArray; dims=:)
    dt = dims_tuple(A, dims)
    res = HloReduce{typeof(op)}(dt)(op,
        HloMap{typeof(f)}()(f, A),
        XRTArray(zero(eltype(A)))
    )
    if dims != (:)
        # Put back the dimensions that HloReduce dropped;
        # Julia semantics require this.
        res = HloReshape(reduced_dimensions_collapes(size(A), dims))(res)
    end
    return res
end

using Flux

function Flux.rand_similar(x::XRTArray{T, Shape}) where {T, Shape}
    HloRng(T, Shape, xla.RandomDistribution.RNG_UNIFORM)(
        XRTArray(zero(T)),
        XRTArray(one(T)))
end
