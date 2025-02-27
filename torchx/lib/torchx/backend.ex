defmodule Torchx.Backend do
  @moduledoc """
  An opaque backend Nx backend with bindings to libtorch/Pytorch.

  Torchx behaviour that is different from BinaryBackend:

    1. Torchx doesn't support u16/u32/u64. Only u8 is supported.

        iex> Nx.tensor([1, 2, 3], type: {:u, 16}, backend: Torchx.Backend)
        ** (ArgumentError) Torchx does not support unsigned 16 bit integer

    2. Torchx doesn't support u8 on sums, you should convert input to signed integer.

        iex> Nx.sum(Nx.tensor([1, 2, 3], type: {:u, 8}, backend: Torchx.Backend))
        ** (ArgumentError) Torchx does not support unsigned 64 bit integer (explicitly cast the input tensor to a signed integer before taking sum)

    3. Torchx rounds half-to-even, while Elixir rounds half-away-from-zero.
       So, in Elixir round(0.5) == 1.0, while in Torchx round(0.5) == 0.0.

        iex> Nx.tensor([-1.5, -0.5, 0.5, 1.5], backend: Torchx.Backend) |> Nx.round()
        #Nx.Tensor<
          f32[4]
          [-2.0, -0.0, 0.0, 2.0]
        >

    While binary backend will do:

        iex> Nx.tensor([-1.5, -0.5, 0.5, 1.5], backend: Nx.BinaryBackend) |> Nx.round()
        #Nx.Tensor<
          f32[4]
          [-2.0, -1.0, 1.0, 2.0]
        >
  """

  @behaviour Nx.Backend
  defstruct [:ref]

  require Application
  alias Nx.Tensor, as: T
  alias Torchx.Backend, as: TB

  ## Creation

  @impl true
  def constant(%T{shape: {}, type: type} = out, scalar, backend_options) do
    Torchx.scalar_tensor(scalar, to_torch_type(type), device_option(backend_options))
    |> to_nx(out)
  end

  def constant(%T{shape: shape, type: type} = out, scalar, backend_options) do
    Torchx.full(shape, scalar, to_torch_type(type), device_option(backend_options))
    |> to_nx(out)
  end

  @impl true
  def eye(%T{shape: {n, n}, type: type} = out, backend_options) do
    Torchx.eye(n, to_torch_type(type), device_option(backend_options)) |> to_nx(out)
  end

  @impl true
  def iota(%T{shape: {}, type: type} = out, nil, backend_options) do
    Torchx.scalar_tensor(0.0, to_torch_type(type), device_option(backend_options))
    |> to_nx(out)
  end

  def iota(%T{shape: shape, type: type} = out, nil, backend_options) do
    Torchx.arange(
      0,
      Nx.size(shape),
      1,
      to_torch_type(type),
      device_option(backend_options),
      shape
    )
    |> to_nx(out)
  end

  @impl true
  def iota(%T{shape: {n}, type: type} = out, 0, backend_options) do
    Torchx.arange(0, n, 1, to_torch_type(type), device_option(backend_options)) |> to_nx(out)
  end

  def iota(%T{shape: shape, type: type} = out, axis, backend_options) do
    # gets the size of iota
    dim = elem(shape, axis)

    # build the iota in one dimension
    aten = Torchx.arange(0, dim, 1, to_torch_type(type), device_option(backend_options))

    # reshape the tensor above to be have shape where everything is 1, except for dim
    reshape = Tuple.duplicate(1, Nx.rank(shape)) |> put_elem(axis, dim)
    aten = Torchx.reshape(aten, reshape)

    # Now broadcast the tensor using the original shape
    Torchx.broadcast_to(aten, shape) |> to_nx(out)
  end

  @impl true
  def random_uniform(%T{type: {s, _} = type, shape: shape} = out, min, max, backend_options)
      when s in [:u, :s] do
    min = to_scalar(min)
    max = to_scalar(max)

    Torchx.randint(min, max, shape, to_torch_type(type), device_option(backend_options))
    |> to_nx(out)
  end

  def random_uniform(%T{type: {f, _} = type, shape: shape} = out, min, max, backend_options)
      when f in [:f, :bf] do
    min = to_scalar(min)
    max = to_scalar(max)

    Torchx.rand(min, max, shape, to_torch_type(type), device_option(backend_options))
    |> to_nx(out)
  end

  @impl true
  def random_normal(%T{type: type, shape: shape} = out, mu, sigma, backend_options) do
    mu = to_scalar(mu)
    sigma = to_scalar(sigma)

    Torchx.normal(mu, sigma, shape, to_torch_type(type), device_option(backend_options))
    |> to_nx(out)
  end

  ## Transfer

  @impl true
  def to_batched_list(%T{shape: shape} = out, %T{} = t, opts) do
    leftover = opts[:leftover]

    batch_size = elem(shape, 0)
    t_axis_0 = elem(t.shape, 0)

    remainder = rem(t_axis_0, batch_size)
    num_full_batches = div(t_axis_0, batch_size)

    num_batches =
      if leftover == :repeat and remainder != 0 do
        num_full_batches + 1
      else
        num_full_batches
      end

    to_batch =
      if remainder != 0 and leftover == :repeat do
        slice_shape = t.shape |> Tuple.delete_at(0) |> Tuple.insert_at(0, remainder)

        t_torchx = from_nx(t)

        slice = torchx_slice(t_torchx, t.shape, slice_shape, [0], [remainder], [1])

        Torchx.concatenate([t_torchx, slice], 0)
      else
        from_nx(t)
      end

    # torch::split returns a chunk with smaller size if the
    # tensor is not fully divisible by the batch_size.
    # We need to drop the last chunk in this case
    case Torchx.split(to_batch, batch_size) do
      batches when remainder != 0 ->
        batches |> Enum.take(num_batches) |> Enum.map(&to_nx(&1, out))

      batches ->
        Enum.map(batches, &to_nx(&1, out))
    end
  end

  @impl true
  def to_binary(tensor, limit) do
    Torchx.to_blob(from_nx(tensor), limit)
  end

  @impl true
  def backend_deallocate(%T{} = t), do: Torchx.delete_tensor(from_nx(t))

  @impl true
  def backend_transfer(tensor, Nx.Tensor, opts) do
    backend_transfer(tensor, Nx.BinaryBackend, opts)
  end

  def backend_transfer(tensor, Torchx.Backend, opts) do
    Torchx.to_device(from_nx(tensor), device_option(opts)) |> to_nx(tensor)
  end

  def backend_transfer(tensor, backend, opts) do
    backend.from_binary(tensor, Torchx.to_blob(from_nx(tensor)), opts)
  end

  @impl true
  def from_binary(%T{type: type, shape: shape} = out, binary, backend_options) do
    Torchx.from_blob(
      binary,
      shape,
      to_torch_type(type),
      device_option(backend_options)
    )
    |> to_nx(out)
  end

  ## Shape

  @impl true
  def reshape(%T{shape: shape} = out, %T{} = t),
    do: Torchx.reshape(from_nx(t), shape) |> to_nx(out)

  @impl true
  def as_type(%T{type: type} = out, %T{} = t),
    do: Torchx.to_type(from_nx(t), to_torch_type(type)) |> to_nx(out)

  @impl true
  def squeeze(out, %T{} = t, _axes) do
    Torchx.squeeze(from_nx(t)) |> to_nx(out)
  end

  # TODO: Handle axes properly
  @impl true
  def broadcast(out, %T{} = t, shape, axes) do
    Torchx.broadcast_to(maybe_reshape(t, shape, axes) |> from_nx(), shape)
    |> to_nx(out)
  end

  defp maybe_reshape(%T{shape: {n}} = t, {n, _}, [0]), do: Nx.reshape(t, {n, 1})
  defp maybe_reshape(%T{} = t, _, _), do: t

  @impl true
  def transpose(out, %T{} = t, axes) do
    Torchx.permute(from_nx(t), axes) |> to_nx(out)
  end

  @impl true
  def slice(
        %T{shape: output_shape} = out,
        %T{shape: input_shape} = t,
        start_indices,
        lengths,
        strides
      ) do
    t
    |> from_nx()
    |> torchx_slice(input_shape, output_shape, start_indices, lengths, strides)
    |> to_nx(out)
  end

  defp torchx_slice(t, input_shape, output_shape, start_indices, lengths, strides) do
    t
    |> narrow(start_indices, lengths, 0, input_shape)
    |> stride(output_shape, lengths, strides)
  end

  defp narrow(ref, [start | starts], [length | lengths], axis, shape) do
    dim = elem(shape, axis)

    # Nothing to narrow
    if start == 0 and length == dim do
      narrow(ref, starts, lengths, axis + 1, shape)
    else
      ref
      |> Torchx.narrow(axis, start, length)
      |> narrow(starts, lengths, axis + 1, shape)
    end
  end

  defp narrow(ref, [], [], _axis, _shape), do: ref

  defp stride(ref, shape, lengths, strides) do
    if Enum.all?(strides, &(&1 == 1)) do
      ref
    else
      ref
      |> Torchx.as_strided(shape, steps_to_strides(lengths, strides), 0)
    end
  end

  def steps_to_strides(shape, steps) do
    for {dim, step} <- Enum.zip(shape, steps) |> Enum.reverse(), reduce: {1, []} do
      {offset, strides} -> {offset * dim, [offset * step | strides]}
    end
    |> elem(1)
  end

  @impl true
  def concatenate(out, tensors, axis) do
    tensors
    |> Enum.map(&from_nx/1)
    |> Torchx.concatenate(axis)
    |> to_nx(out)
  end

  @impl true
  def take(out, t, i, axis) do
    axes_range = 0..(Nx.rank(t) - 1)//1

    indices_shape =
      axes_range
      |> Enum.flat_map(fn
        ^axis -> Tuple.to_list(i.shape)
        _ -> [1]
      end)
      |> List.to_tuple()

    idx_tiling =
      t.shape
      |> Tuple.to_list()
      |> Enum.with_index(fn
        _x, ^axis ->
          List.duplicate(1, Nx.rank(i))

        x, _ ->
          x
      end)
      |> List.flatten()

    indices_for_axis =
      i
      |> Nx.reshape(indices_shape)
      |> Nx.tile(idx_tiling)

    num_elements = Tuple.product(indices_for_axis.shape)

    axis_offset = Nx.rank(i) - 1

    indices =
      axes_range
      |> Enum.map(fn
        ^axis ->
          Nx.reshape(indices_for_axis, {num_elements, 1})

        current when current < axis ->
          indices_for_axis
          |> Nx.iota(axis: current, backend: __MODULE__)
          |> Nx.reshape({num_elements, 1})

        current when current > axis ->
          indices_for_axis
          |> Nx.iota(axis: current + axis_offset, backend: __MODULE__)
          |> Nx.reshape({num_elements, 1})
      end)
      |> Nx.concatenate(axis: 1)

    gather(out, t, indices)
  end

  @impl true
  def gather(out, tensor, idx) do
    # Nx provides indices as a tensor of shape {*, input_dims}
    # However, torch expects indices to be a tensor of indices along a given axis.
    # As such, we need to convert the indices tensor to linear indices.
    # See the function below for an explanation on the offsets calculation

    linear_indices_offsets =
      tensor.shape
      |> linear_indices_offsets()
      |> from_nx()

    lin_idx_num_elements =
      idx.shape |> Tuple.delete_at(tuple_size(idx.shape) - 1) |> Tuple.product()

    linear_indices =
      idx
      |> from_nx()
      |> Torchx.tensordot(linear_indices_offsets, [tuple_size(idx.shape) - 1], [0])
      |> Torchx.reshape({lin_idx_num_elements})

    tensor
    |> from_nx()
    |> Torchx.reshape({Tuple.product(tensor.shape)})
    |> Torchx.gather(linear_indices, 0)
    |> Torchx.reshape(out.shape)
    |> to_nx(out)
  end

  defp linear_indices_offsets(shape) do
    # The offsets tensor calculated below follows a formula in which we
    # multiply the index along each axis by the number of elements contained in all following axes
    # For example, for a {3, 5, 7, 2} tensor, the offsets tensor is [70, 14, 2, 1]

    # This offsets tensor is then applied to the indices tensor through matrix multiplication:
    # indices = [[0, 2, 1, 0], [0, 0, 0, 1], [1, 4, 3, 2]]
    # offsets = [70, 14, 2, 1]
    # linear_indices = [14 * 2 + 2 * 1, 1 * 1, 70 * 1 + 14 * 4 + 2 * 3 + 1 * 2] = [30, 1, 134]

    # By linear indices, we refer to the indices of a row-major representation of a tensor
    # it's easy to see the expected values using Nx.iota(tensor), which will output a tensor
    # which counts in exactly the same way, when provided no arguments. In effect, Nx.iota outputs
    # the corresponding linear indices for a given tensor shape.

    {offsets_list, _} =
      shape
      |> Tuple.to_list()
      |> Enum.reverse()
      |> Enum.reduce({[], 1}, fn x, {acc, multiplier} ->
        {[multiplier | acc], multiplier * x}
      end)

    Nx.tensor(offsets_list, backend: __MODULE__)
  end

  @impl true
  def take_along_axis(out, tensor, idx, axis) do
    tensor
    |> from_nx()
    |> Torchx.gather(from_nx(idx), axis)
    |> to_nx(out)
  end

  @impl true
  def argsort(out, tensor, opts) do
    axis = opts[:axis]
    is_descending = opts[:direction] == :desc

    tensor
    |> from_nx()
    |> Torchx.argsort(axis, is_descending)
    |> to_nx(out)
  end

  @impl true
  def reverse(out, tensor, axes) do
    tensor
    |> from_nx()
    |> Torchx.flip(axes)
    |> to_nx(out)
  end

  ## Aggregators

  @impl true
  def sum(%T{type: out_type} = out, %T{} = t, opts) do
    check_type!(out_type)

    axes = opts[:axes] || []
    keep_axes = opts[:keep_axes] || false

    Torchx.sum(from_nx(t), axes, keep_axes) |> to_nx(out)
  end

  @impl true
  def product(%T{type: out_type} = out, %T{} = t, opts) do
    check_type!(out_type)

    axes = opts[:axes] || []
    keep_axes = opts[:keep_axes] || false

    result =
      if axes == [] do
        product_whole_tensor(t, keep_axes)
      else
        product_over_axes(t, axes, keep_axes)
      end

    to_nx(result, out)
  end

  defp product_whole_tensor(t, keep_axes) do
    prod =
      t
      |> from_nx()
      |> Torchx.product()

    if keep_axes do
      shape = t.shape |> Tuple.delete_at(-1) |> Tuple.append(1)
      Torchx.reshape(prod, shape)
    else
      prod
    end
  end

  defp product_over_axes(t, axes, keep_axes) do
    {_, result_tx} =
      for _ <- 1..length(axes), reduce: {axes, from_nx(t)} do
        {[], t_tx} ->
          {[], t_tx}

        {[axis | axes], t_tx} ->
          # We need to offset all subsequent axes if keep_axes == false.
          # If keep_axes == true, we can use the same axis numbers as the
          # incoming tensor.
          axes =
            if keep_axes do
              axes
            else
              for x <- axes do
                if x > axis, do: x - 1, else: x
              end
            end

          {axes, Torchx.product(t_tx, axis, keep_axes)}
      end

    result_tx
  end

  @impl true
  def argmax(%T{} = out, %T{} = t, opts) do
    unsupported_option!(opts, :tie_break, :low)

    axis = opts[:axis] || -1
    keep_axes = opts[:keep_axes] || false

    Torchx.argmax(from_nx(t), axis, keep_axes) |> to_nx(out)
  end

  @impl true
  def argmin(%T{} = out, %T{} = t, opts) do
    unsupported_option!(opts, :tie_break, :low)

    axis = opts[:axis] || -1
    keep_axes = opts[:keep_axes] || false

    Torchx.argmin(from_nx(t), axis, keep_axes) |> to_nx(out)
  end

  @impl true
  def all?(%T{} = out, %T{} = t, opts) do
    axes =
      case opts[:axes] do
        axes when length(axes) in 0..1 ->
          axes

        nil ->
          []

        _axes ->
          raise ArgumentError, ":axes option only accepts a single axis per call"
      end

    keep_axes = opts[:keep_axes] || false

    t
    |> from_nx()
    |> Torchx.all(axes, keep_axes)
    |> to_nx(out)
  end

  ## Ops

  binary_ops =
    [:add, :subtract, :multiply, :power, :remainder, :divide, :atan2, :min, :max, :quotient] ++
      [:left_shift, :right_shift] ++
      [:equal, :not_equal, :greater, :less, :greater_equal, :less_equal] ++
      [:logical_and, :logical_or, :logical_xor]

  for op <- binary_ops do
    @impl true
    def unquote(op)(out, l, r) do
      {left, right} = maybe_cast_u8(l, r)

      Torchx.unquote(op)(from_nx(left), from_nx(right))
      |> to_nx(out)
    end
  end

  defp maybe_cast_u8(%T{type: {t, _}} = left, %T{type: {t, _}} = right),
    do: {left, right}

  defp maybe_cast_u8(%T{type: {:u, 8}} = left, %T{} = right),
    do: {Nx.as_type(left, {:s, 16}), right}

  defp maybe_cast_u8(%T{} = left, %T{type: {:u, 8}} = right),
    do: {left, Nx.as_type(right, {:s, 16})}

  defp maybe_cast_u8(left, right),
    do: {left, right}

  for op <- [:bitwise_and, :bitwise_or, :bitwise_xor] do
    @impl true
    def unquote(op)(out, l, r) do
      {left, right} = maybe_cast_u8(l, r)

      %T{type: {_, size_left}} = left
      %T{type: {_, size_right}} = right

      if size_left >= size_right do
        Torchx.unquote(op)(from_nx(left), from_nx(right))
      else
        Torchx.unquote(op)(from_nx(right), from_nx(left))
      end
      |> to_nx(out)
    end
  end

  unary_ops =
    [:exp, :expm1, :log, :log1p, :logistic, :cos, :sin, :tan, :cosh, :sinh] ++
      [:tanh, :acos, :asin, :atan, :acosh, :asinh, :atanh, :sqrt, :rsqrt] ++
      [:erf, :erfc, :erf_inv, :abs, :bitwise_not, :ceil, :floor, :negate, :round, :sign]

  for op <- unary_ops do
    @impl true
    def unquote(op)(out, tensor) do
      Torchx.unquote(op)(from_nx(tensor)) |> to_nx(out)
    end
  end

  @impl true
  def dot(
        %T{type: out_type} = out,
        %T{type: left_type, data: %TB{ref: left_ref}},
        left_axes,
        [],
        %T{type: right_type, data: %TB{ref: right_ref}},
        right_axes,
        []
      ) do
    Torchx.tensordot(
      to_typed_ref(left_ref, left_type, out_type),
      to_typed_ref(right_ref, right_type, out_type),
      left_axes,
      right_axes
    )
    |> to_nx(out)
  end

  @impl true
  def cholesky(%T{} = out, %T{} = t) do
    t
    |> from_nx()
    |> Torchx.cholesky()
    |> to_nx(out)
  end

  @impl true
  def qr({q_holder, r_holder}, tensor, opts) do
    {q, r} = Torchx.qr(from_nx(tensor), opts[:mode] == :reduced)
    {to_nx(q, q_holder), to_nx(r, r_holder)}
  end

  @impl true
  def lu(
        {p_holder, %{type: output_type} = l_holder, %{type: output_type} = u_holder},
        tensor,
        _opts
      ) do
    out_type = to_torch_type(output_type)

    {p_tx, l_tx, u_tx} =
      tensor
      |> from_nx()
      |> Torchx.to_type(out_type)
      |> Torchx.lu()

    p_type = to_torch_type(p_holder.type)

    # p_type can be an integer type, but we can
    # demote the floating-point torch tensor
    # without any loss because p_tx is a tensor
    # of zeros or ones only

    p =
      p_tx
      |> Torchx.to_type(p_type)
      |> to_nx(p_holder)

    l = to_nx(l_tx, l_holder)
    u = to_nx(u_tx, u_holder)

    {p, l, u}
  end

  @impl true
  def triangular_solve(%T{} = out, %T{} = a, %T{} = b, opts) do
    transform = opts[:transform_a]
    upper = !opts[:lower]
    left_side = opts[:left_side]

    # We can support this eventually, but we'd need
    # to apply the same permutations BinaryBackend applies,
    # because this is not natively supported by libtorch
    unless left_side do
      raise ArgumentError, "left_side: false option not supported in Torchx"
    end

    batched_a_shape = Tuple.insert_at(a.shape, 0, 1)

    batched_b_shape =
      case b.shape do
        {n} -> {1, n, 1}
        {m, n} -> {1, m, n}
      end

    out_type = to_torch_type(out.type)

    a_tx =
      a
      |> from_nx()
      |> Torchx.reshape(batched_a_shape)
      |> Torchx.to_type(out_type)

    eps = 1.0e-10 |> Nx.tensor() |> Torchx.from_nx()

    # We need to manually validate if the A tensor is singular
    # (i.e. the tensor has its determinant equal to 0)
    # Otherwise, an exception will be thrown by libtorch.
    #
    # a non-zero eps value is chosen so we can account for possible rounding errors
    # in the determinant calculation
    is_singular =
      a_tx
      |> Torchx.determinant()
      |> Torchx.abs()
      |> Torchx.reshape({})
      |> Torchx.less_equal(eps)
      |> Torchx.to_nx()
      |> Nx.backend_transfer(Nx.BinaryBackend)

    if Nx.tensor(1, type: {:u, 8}, backend: Nx.BinaryBackend) == is_singular do
      raise ArgumentError, "can't solve for singular matrix"
    end

    b_tx = b |> from_nx() |> Torchx.reshape(batched_b_shape) |> Torchx.to_type(out_type)

    a_tx
    |> Torchx.triangular_solve(b_tx, transform == :transpose, upper)
    |> Torchx.reshape(out.shape)
    |> Torchx.to_nx()
  end

  @impl true
  def sort(%T{} = out, %T{} = t, opts) do
    axis = opts[:axis]
    descending = opts[:direction] == :desc

    t
    |> from_nx()
    |> Torchx.sort(axis, descending)
    |> to_nx(out)
  end

  @impl true
  def inspect(%T{} = tensor, inspect_opts) do
    result =
      if device?(tensor, :cpu) do
        binary = Torchx.to_blob(from_nx(tensor))
        Nx.Backend.inspect(tensor, binary, inspect_opts)
      else
        "Tensors on the GPU cannot be inspected. Explicitly transfer the tensor by calling Nx.backend_transfer/1"
      end

    maybe_add_signature(result, tensor)
  end

  # TODO: Elixir v1.13 has a default_inspect_fun which
  # we can use to customize this behaviour for tests.
  if Application.compile_env(:torchx, :add_backend_on_inspect, true) do
    defp maybe_add_signature(result, %T{data: %TB{ref: {device, _}}}) do
      Inspect.Algebra.concat([
        "Torchx.Backend(#{device})",
        Inspect.Algebra.line(),
        result
      ])
    end
  else
    defp maybe_add_signature(result, _tensor) do
      result
    end
  end

  ## Conversions

  @doc false
  def from_nx(%T{data: %TB{ref: device_ref}}), do: device_ref
  def from_nx(%T{} = tensor), do: Nx.backend_transfer(tensor, TB) |> from_nx()

  @doc false
  def to_nx({device, ref} = device_ref, %T{type: type, shape: shape} = t)
      when is_atom(device) and is_reference(ref) do
    %{t | data: %__MODULE__{ref: check_shape_and_type!(device_ref, shape, type)}}
  end

  @doc false
  def from_torch_type(:char), do: {:s, 8}
  def from_torch_type(:byte), do: {:u, 8}
  def from_torch_type(:bool), do: {:u, 8}
  def from_torch_type(:short), do: {:s, 16}
  def from_torch_type(:int), do: {:s, 32}
  def from_torch_type(:long), do: {:s, 64}
  def from_torch_type(:brain), do: {:bf, 16}
  def from_torch_type(:half), do: {:f, 16}
  def from_torch_type(:float), do: {:f, 32}
  def from_torch_type(:double), do: {:f, 64}

  defp to_torch_type(nx_type, hint \\ "")
  defp to_torch_type({:u, 8}, _), do: :byte
  defp to_torch_type({:s, 8}, _), do: :char
  defp to_torch_type({:s, 16}, _), do: :short
  defp to_torch_type({:s, 32}, _), do: :int
  defp to_torch_type({:s, 64}, _), do: :long
  defp to_torch_type({:bf, 16}, _), do: :brain
  defp to_torch_type({:f, 16}, _), do: :half
  defp to_torch_type({:f, 32}, _), do: :float
  defp to_torch_type({:f, 64}, _), do: :double

  defp to_torch_type({:u, size}, hint) when size in [16, 32, 64] do
    raise ArgumentError,
          String.trim("Torchx does not support unsigned #{size} bit integer#{hint}")
  end

  if Application.compile_env(:torchx, :check_shape_and_type, false) do
    defp check_shape_and_type!(device_ref, shape, type) do
      current_type = Torchx.scalar_type(device_ref) |> from_torch_type()

      if current_type != type do
        raise "type mismatch in Torchx: expected #{inspect(type)}, got: #{inspect(current_type)}. " <>
                "Please report this bug"
      end

      current_shape = Torchx.shape(device_ref)

      if current_shape != shape do
        raise "shape mismatch in Torchx: expected #{inspect(shape)}, got: #{inspect(current_shape)}. " <>
                "Please report this bug"
      end

      device_ref
    end
  else
    defp check_shape_and_type!(device_ref, _, _), do: device_ref
  end

  ## Helpers

  defp to_scalar(n) when is_number(n), do: n
  defp to_scalar(%T{} = t), do: t |> from_nx() |> Torchx.item()

  defp to_typed_ref(tensor, expected_type, expected_type),
    do: tensor

  defp to_typed_ref(tensor, _ref_type, expected_type),
    do: Torchx.to_type(tensor, to_torch_type(expected_type))

  defp device?(%T{data: %TB{ref: {actual, _}}}, expected), do: expected == actual

  defp device_option(nil), do: {:cpu, -1}
  defp device_option(backend_opts), do: backend_opts[:device] || {:cpu, -1}

  defp unsupported_option!(opts, key, acceptable_default) do
    if opts[key] != acceptable_default do
      raise "#{inspect(key)} option is not supported in #{caller()}"
    end
  end

  defp caller(depth \\ 3) do
    {module, func, arity, [file: _file, line: _line]} =
      Process.info(self(), :current_stacktrace) |> elem(1) |> Enum.fetch!(depth)

    "#{inspect(module)}.#{func}/#{arity - 1}"
  end

  defp check_type!(type) do
    to_torch_type(
      type,
      " (explicitly cast the input tensor to a signed integer before taking sum)"
    )
  end

  ## Functionality we can't provide

  not_possible = [bitcast: 2, map: 4, population_count: 2, reduce: 5, window_reduce: 6]

  for {fun, arity} <- not_possible do
    args = Macro.generate_arguments(arity, __MODULE__)

    @impl true
    def unquote(fun)(unquote_splicing(args)) do
      raise "operation #{unquote(fun)} is not supported on Torchx.Backend"
    end
  end

  ## All remaining callbacks

  funs = Nx.Backend.behaviour_info(:callbacks) -- Module.definitions_in(__MODULE__, :def)

  @doc false
  def __unimplemented__, do: unquote(funs ++ not_possible)

  for {fun, arity} <- funs do
    args = Macro.generate_arguments(arity, __MODULE__)

    @impl true
    def unquote(fun)(unquote_splicing(args)) do
      raise "operation #{unquote(fun)} is not yet supported on Torchx.Backend"
    end
  end
end
