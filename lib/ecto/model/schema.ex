defmodule Ecto.Model.Schema do
  @moduledoc """
  Defines a schema for a model.

  A schema is a struct with associated metadata that is persisted to a
  repository. Every schema model is also a struct, that means that you work
  with models just like you would work with structs.

  ## Example

      defmodule User do
        use Ecto.Model.Schema

        schema "users" do
          field :name, :string
          field :age, :integer, default: 0
          has_many :posts, Post
        end
      end

  ## Types and casting

  When defining the schema, types need to be given. Those types are specific
  to Ecto and must be one of:

  Ecto type               | Elixir type             | Literal syntax in query
  :---------------------- | :---------------------- | :---------------------
  `:integer`              | `integer`               | 1, 2, 3
  `:float`                | `float`                 | 1.0, 2.0, 3.0
  `:boolean`              | `boolean`               | true, false
  `:string`               | UTF-8 encoded `binary`  | "hello"
  `:binary`               | `binary`                | `<<int, int, int, ...>>`
  `:uuid`                 | 16 byte `binary`        | `uuid(binary_or_string)`
  `{:array, inner_type}`  | `list`                  | `[value, value, value, ...]`
  `:decimal`              | [`Decimal`](https://github.com/ericmj/decimal)
  `:datetime`             | `%Ecto.DateTime{}`
  `:date`                 | `%Ecto.Date{}`
  `:time`                 | `%Ecto.Time{}`

  Models can also have virtual fields by passing the `virtual: true`
  option. These fields are not persisted to the database and can
  optionally not be type checked by declaring type `:any`.

  When manipulating the struct, it is the responsibility of the
  developer to ensure the fields are cast to the proper value. For
  example, you can create a weather struct with an invalid value
  for `temp_lo`:

      iex> weather = %Weather{temp_lo: "0"}
      iex> weather.temp_lo
      "0"

  However, if you attempt to persist the struct above, an error will
  be raised since Ecto validates the types when building the query.

  ## Schema defaults

  When using the block syntax, the created model uses the default
  of a primary key named `:id`, of type `:integer`. This can be
  customized by passing `primary_key: false` to schema:

      schema "weather", primary_key: false do
        ...
      end

  Or by passing a tuple in the format `{field, type, opts}`:

      schema "weather", primary_key: {:custom_field, :string, []} do
        ...
      end

  Implicit defaults can be specified via the `@schema_defaults` attribute.
  This is useful if you want to use a different default primary key
  through your entire application.

  The supported options are:

  * `primary_key` - either `false`, or a `{field, type, opts}` tuple
  * `foreign_key_type` - sets the type for any `belongs_to` associations.
    This can be overridden using the `:type` option to the `belongs_to`
    statement. Defaults to type `:integer`

  ## Example

      defmodule MyApp.Model do
        defmacro __using__(_) do
          quote do
            @schema_defaults primary_key: {:uuid, :string, []},
                             foreign_key_type: :string
            use Ecto.Model
          end
        end
      end

      defmodule MyApp.Post do
        use MyApp.Model
        schema "posts" do
          has_many :comments, MyApp.Comment
        end
      end

      defmodule MyApp.Comment do
        use MyApp.Model
        schema "comments" do
          belongs_to :post, MyApp.Comment
        end
      end

  Any models using `MyApp.Model will get the `:uuid` field, with type
  `:string` as the primary key.

  The `belongs_to` association on `MyApp.Comment` will also now require
  that `:post_id` be of `:string` type to reference the `:uuid` of a
  `MyApp.Post` model.

  ## Reflection

  Any schema module will generate the `__schema__` function that can be used for
  runtime introspection of the schema.

  * `__schema__(:source)` - Returns the source as given to `schema/2`;
  * `__schema__(:primary_key)` - Returns the field that is the primary key or
                                 `nil` if there is none;

  * `__schema__(:fields)` - Returns a list of all non-virtual field names;
  * `__schema__(:field, field)` - Returns the type of the given non-virtual field;

  * `__schema__(:associations)` - Returns a list of all association field names;
  * `__schema__(:association, assoc)` - Returns the association reflection of the given assoc;

  * `__schema__(:load, values, idx)` - Loads a new model struct from a tuple of non-virtual
                                       field values starting at the given index;

  Furthermore, both `__struct__` and `__assign__` functions are defined
  so structs and assignment functionalities are available.
  """

  @doc false
  defmacro __using__(_) do
    quote do
      import Ecto.Model.Schema, only: [schema: 2, schema: 3]
    end
  end

  @doc """
  Defines a schema with a source name and field definitions.
  """
  defmacro schema(source, opts \\ [], block)

  defmacro schema(source, opts, [do: block]) do
    quote do
      source = unquote(source)

      unless is_binary(source) do
        raise ArgumentError, "schema source must be a string, got: #{inspect source}"
      end

      # TODO: Revisit @schema_defaults and primary_key configuration
      opts = (Module.get_attribute(__MODULE__, :schema_defaults) || [])
             |> Keyword.merge(unquote(opts))

      Module.register_attribute(__MODULE__, :assign_fields, accumulate: true)
      Module.register_attribute(__MODULE__, :struct_fields, accumulate: true)
      Module.register_attribute(__MODULE__, :ecto_fields, accumulate: true)
      Module.register_attribute(__MODULE__, :ecto_assocs, accumulate: true)

      @ecto_primary_key nil
      @ecto_foreign_key_type opts[:foreign_key_type]

      case opts[:primary_key] do
        nil ->
          Ecto.Model.Schema.field(:id, :integer, primary_key: true)
        false ->
          :ok
        {name, type, opts} ->
          Ecto.Model.Schema.field(name, type, Keyword.put(opts, :primary_key, true))
        other ->
          raise ArgumentError, ":primary_key must be false or {name, type, opts}"
      end

      try do
        import Ecto.Model.Schema
        unquote(block)
      after
        :ok
      end

      fields = @ecto_fields |> Enum.reverse
      assocs = @ecto_assocs |> Enum.reverse

      Module.eval_quoted __MODULE__, [
        Ecto.Model.Schema.__struct__(@struct_fields),
        Ecto.Model.Schema.__assign__(@assign_fields, @ecto_primary_key),
        Ecto.Model.Schema.__source__(source),
        Ecto.Model.Schema.__fields__(fields),
        Ecto.Model.Schema.__assocs__(__MODULE__, assocs, @ecto_primary_key, fields),
        Ecto.Model.Schema.__primary_key__(@ecto_primary_key),
        Ecto.Model.Schema.__helpers__(fields)]
    end
  end

  ## API

  @doc """
  Defines a field on the model schema with given name and type.

  ## Options

    * `:default` - Sets the default value on the schema and the struct
    * `:virtual` - When true, the field is not persisted
    * `:primary_key` - When true, the field is set as primary key

  """
  defmacro field(name, type \\ :string, opts \\ []) do
    quote do
      Ecto.Model.Schema.__field__(__MODULE__, unquote(name), unquote(type), unquote(opts))
    end
  end

  @doc """
  Defines an association.

  This macro is used by `belongs_to/3`, `has_one/3` and `has_many/3` to
  define associations. However, custom association mechanisms can be provided
  by developers and hooked in via this macro.

  Read more about custom associations in `Ecto.Associations`.
  """
  defmacro association(name, association, opts \\ []) do
    quote do
      Ecto.Model.Schema.__association__(__MODULE__, unquote(name), unquote(association), unquote(opts))
    end
  end

  @doc ~S"""
  Indicates a one-to-many association with another model.

  The current model has zero or more records of the other model. The other
  model often has a `belongs_to` field with the reverse association.

  ## Options

    * `:foreign_key` - Sets the foreign key, this should map to a field on the
      other model, defaults to the underscored name of the current model
      suffixed by `_id`

    * `:references` - Sets the key on the current model to be used for the
      association, defaults to the primary key on the model;

  ## Examples

      defmodule Post do
        schema "posts" do
          has_many :comments, Comment
        end
      end

      # Get all comments for a given post
      post = Repo.get(Post, 42)
      comments = Repo.all assoc(post, :comments)

      # The comments can come preloaded on the post struct
      [post] = Repo.all(from(p in Post, where: p.id == 42, preload: :comments))
      post.comments #=> [ %Comment{...}, ... ]

  """
  defmacro has_many(name, queryable, opts \\ []) do
    quote bind_quoted: binding() do
      association(name, Ecto.Associations.Has,
                  [queryable: queryable, cardinality: :many] ++ opts)
    end
  end

  @doc ~S"""
  Indicates a one-to-one association with another model.

  The current model has zero or one records of the other model. The other
  model often has a `belongs_to` field with the reverse association.

  ## Options

    * `:foreign_key` - Sets the foreign key, this should map to a field on the
      other model, defaults to the underscored name of the current model
      suffixed by `_id`

    * `:references`  - Sets the key on the current model to be used for the
      association, defaults to the primary key on the model

  ## Examples

      defmodule Post do
        schema "posts" do
          has_one :permalink, Permalink
        end
      end

      # The permalink can come preloaded on the post struct
      [post] = Repo.all(from(p in Post, where: p.id == 42, preload: :permalink))
      post.permalink #=> %Permalink{...}

  """
  defmacro has_one(name, queryable, opts \\ []) do
    quote bind_quoted: binding() do
      association(name, Ecto.Associations.Has,
                  [queryable: queryable, cardinality: :one] ++ opts)
    end
  end

  @doc ~S"""
  Indicates a one-to-one association with another model.

  The current model belongs to zero or one records of the other model. The other
  model often has a `has_one` or a `has_many` field with the reverse association.

  You should use `belongs_to` in the table that contains the foreign key. Imagine
  a company <-> manager relationship. If the company contains the `manager_id` in
  the underlying database table, we say the company belongs to manager.

  In fact, when you invoke this macro, a field with the name of foreign key is
  automatically defined in the schema for you.

  ## Options

    * `:foreign_key` - Sets the foreign key field name, defaults to the name
      of the association suffixed by `_id`. For example, `belongs_to :company`
      will have foreign key of `:company_id`

    * `:references` - Sets the key on the other model to be used for the
      association, defaults to: `:id`

    * `:type` - Sets the type of `:foreign_key`. Defaults to: `:integer`

  ## Examples

      defmodule Comment do
        schema "comments" do
          # This automatically defines a post_id field too
          belongs_to :post, Post
        end
      end

      # The post can come preloaded on the comment record
      [comment] = Repo.all(from(c in Comment, where: c.id == 42, preload: :post))
      comment.post #=> %Post{...}

  """
  defmacro belongs_to(name, queryable, opts \\ []) do
    quote bind_quoted: binding() do
      opts = Keyword.put_new(opts, :foreign_key, :"#{name}_id")

      foreign_key_type =
        opts[:type] || @ecto_foreign_key_type || :integer

      field(opts[:foreign_key], foreign_key_type, [])

      association(name, Ecto.Associations.BelongsTo, [queryable: queryable] ++ opts)
    end
  end

  ## Callbacks

  @doc false
  def __field__(mod, name, type, opts) do
    check_type!(type, opts[:virtual])

    if opts[:primary_key] do
      if pk = Module.get_attribute(mod, :ecto_primary_key) do
        raise ArgumentError, message: "primary key already defined as `#{pk}`"
      else
        Module.put_attribute(mod, :ecto_primary_key, name)
      end
    end

    # TODO: Check that the opts are valid for the given type,
    # especially check the default value

    Module.put_attribute(mod, :assign_fields, {name, type})
    put_struct_field(mod, name, opts[:default])

    unless opts[:virtual] do
      Module.put_attribute(mod, :ecto_fields, {name, type, opts})
    end
  end

  @doc false
  def __association__(mod, name, association, opts) do
    put_struct_field(mod, name,
                     %Ecto.Associations.NotLoaded{__owner__: mod, __field__: name})
    Module.put_attribute(mod, :ecto_assocs, {name, association, opts})
  end

  defp put_struct_field(mod, name, assoc) do
    fields = Module.get_attribute(mod, :struct_fields)

    if List.keyfind(fields, name, 0) do
      raise ArgumentError, message: "field/association `#{name}` is already set on schema"
    end

    Module.put_attribute(mod, :struct_fields, {name, assoc})
  end

  ## Quoted callbacks

  @doc false
  def __assign__(assign_fields, primary_key) do
    map = assign_fields |> Enum.into(%{}) |> Map.delete(primary_key) |> Macro.escape()
    quote do
      def __assign__ do
        unquote(map)
      end
    end
  end

  @doc false
  def __struct__(struct_fields) do
    quote do
      defstruct unquote(Macro.escape(struct_fields))
    end
  end

  @doc false
  def __source__(source) do
    quote do
      def __schema__(:source), do: unquote(Macro.escape(source))
    end
  end

  @doc false
  def __fields__(fields) do
    quoted = Enum.map(fields, fn {name, type, _opts} ->
      quote do
        def __schema__(:field, unquote(name)), do: unquote(type)
      end
    end)

    field_names = Enum.map(fields, &elem(&1, 0))

    quoted ++ [quote do
      def __schema__(:field, _), do: nil
      def __schema__(:fields), do: unquote(field_names)
    end]
  end

  @doc false
  def __assocs__(module, assocs, primary_key, fields) do
    fields = Enum.map(fields, &elem(&1, 0))

    quoted = Enum.map(assocs, fn {name, type, opts} ->
      refl = type.struct(name, module, primary_key, fields, opts)

      quote do
        def __schema__(:association, unquote(name)) do
          unquote(Macro.escape(refl))
        end
      end
    end)

    assoc_names = Enum.map(assocs, &elem(&1, 0))

    quote do
      def __schema__(:associations), do: unquote(assoc_names)
      unquote(quoted)
      def __schema__(:association, _), do: nil
    end
  end

  @doc false
  def __primary_key__(primary_key) do
    quote do
      def __schema__(:primary_key), do: unquote(primary_key)
    end
  end

  @doc false
  def __helpers__(fields) do
    field_names = Enum.map(fields, &elem(&1, 0))

    quote do
      def __schema__(:load, values, idx) do
        Enum.reduce(unquote(field_names), {__struct__(), idx}, fn
          field, {struct, idx} ->
            {Map.put(struct, field, elem(values, idx)), idx + 1}
        end) |> elem(0)
      end
    end
  end

  defp check_type!(type, virtual?) do
    cond do
      type == :any and not virtual? ->
        raise ArgumentError, "only virtual fields can have type :any"
      Ecto.Query.Types.primitive?(type) ->
        true
      true ->
        raise ArgumentError, "unknown field type `#{inspect type}`"
    end
  end
end
