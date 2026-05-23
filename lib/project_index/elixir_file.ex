defmodule ProjectIndex.ElixirFile do
  @moduledoc false

  def parse(path) do
    source = File.read!(path)

    case Sourceror.parse_string(source) do
      {:ok, ast} ->
        %{path: path, modules: extract_modules(ast, path)}

      {:error, error} ->
        %{path: path, modules: [parse_error_module(path, error)]}
    end
  end

  defp extract_modules(ast, path) do
    modules =
      ast
      |> ast_roots()
      |> Enum.reduce([], fn root_ast, acc ->
        {_ast, modules} =
          Macro.prewalk(root_ast, acc, &collect_module(&1, &2, path))

        modules
      end)

    modules
    |> Enum.reverse()
    |> Enum.sort_by(&{&1.path, &1.name || ""})
  end

  defp parse_error_module(path, error) do
    %{
      name: nil,
      path: path,
      parse_error: inspect(error),
      moduledoc?: false,
      specs?: false,
      docs_count: 0,
      public_funs: [],
      uses: []
    }
  end

  defp collect_module({:defmodule, _meta, args} = node, acc, path) do
    case module_parts(args) do
      {module_ast, block} -> {node, [module_metadata(module_ast, block, path) | acc]}
      :error -> {node, acc}
    end
  end

  defp collect_module(node, acc, _path), do: {node, acc}

  defp module_metadata(module_ast, block, path) do
    %{
      name: module_name(module_ast),
      path: path,
      parse_error: nil,
      moduledoc?: has_attribute?(block, :moduledoc),
      specs?: has_attribute?(block, :spec),
      docs_count: count_docs(block),
      public_funs: public_funs(block),
      uses: used_modules(block)
    }
  end

  defp ast_roots(ast) when is_list(ast), do: ast
  defp ast_roots(ast), do: [ast]

  defp module_name({:__aliases__, _meta, parts}), do: Enum.join(parts, ".")
  defp module_name(other), do: Macro.to_string(other)

  defp module_parts([module_ast, body]) when is_list(body) do
    case fetch_do_block(body) do
      {:ok, block} -> {module_ast, block}
      :error -> :error
    end
  end

  defp module_parts(_args), do: :error

  defp fetch_do_block(body) do
    Enum.find_value(body, :error, fn
      {:do, block} -> {:ok, block}
      {key_ast, block} -> if sourceror_keyword_key(key_ast) == :do, do: {:ok, block}
      _other -> nil
    end)
  end

  defp sourceror_keyword_key({:__block__, _meta, [key]}) when is_atom(key), do: key
  defp sourceror_keyword_key(_other), do: nil

  defp has_attribute?(block, attribute) do
    {_ast, found?} =
      Macro.prewalk(block, false, fn
        {:@, _meta, [{^attribute, _attribute_meta, _args}]} = node, _found? -> {node, true}
        node, found? -> {node, found?}
      end)

    found?
  end

  defp count_docs(block) do
    {_ast, count} =
      Macro.prewalk(block, 0, fn
        {:@, _meta, [{attribute, _attribute_meta, _args}]} = node, count
        when attribute in [:doc, :typedoc] ->
          {node, count + 1}

        node, count ->
          {node, count}
      end)

    count
  end

  defp public_funs(block) do
    {_ast, funs} =
      Macro.prewalk(block, [], fn
        {:def, _meta, [{name, _fun_meta, args_ast} | _rest]} = node, acc when is_atom(name) ->
          arity = if is_list(args_ast), do: length(args_ast), else: 0
          {node, [%{name: Atom.to_string(name), arity: arity} | acc]}

        node, acc ->
          {node, acc}
      end)

    funs
    |> Enum.reverse()
    |> Enum.uniq()
  end

  defp used_modules(block) do
    {_ast, modules} =
      Macro.prewalk(block, [], fn
        {:use, _meta, [module_ast | _args]} = node, acc ->
          {node, [Macro.to_string(module_ast) | acc]}

        node, acc ->
          {node, acc}
      end)

    modules
    |> Enum.reverse()
    |> Enum.uniq()
    |> Enum.sort()
  end
end
