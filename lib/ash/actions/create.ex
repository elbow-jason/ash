defmodule Ash.Actions.Create do
  @moduledoc false
  alias Ash.Actions.Relationships
  alias Ash.Engine
  alias Ash.Engine.Request
  require Logger

  @spec run(Ash.api(), Ash.changeset(), Ash.action(), Keyword.t()) ::
          {:ok, Ash.record()} | {:error, Ash.error()}
  def run(api, changeset, action, opts) do
    upsert? = opts[:upsert?] || false
    resource = changeset.resource

    engine_opts =
      opts
      |> Keyword.take([:verbose?, :actor, :authorize?])
      |> Keyword.put(:transaction?, true)

    with %{valid?: true} = changeset <- changeset(changeset, api),
         :ok <- check_upsert_support(changeset.resource, upsert?),
         %{
           data: %{commit: %^resource{} = created},
           errors: []
         } <-
           do_run_requests(
             changeset,
             upsert?,
             engine_opts,
             action,
             resource,
             api
           ) do
      {:ok, created}
    else
      %Ash.Changeset{errors: errors} ->
        {:error, Ash.Error.to_ash_error(errors)}

      %{errors: errors} ->
        {:error, Ash.Error.to_ash_error(errors)}

      {:error, error} ->
        {:error, Ash.Error.to_ash_error(error)}
    end
  end

  defp changeset(changeset, api) do
    %{changeset | api: api}
    |> Relationships.handle_relationship_changes()
    |> set_defaults()
    |> add_validations()
  end

  defp add_validations(changeset) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      changeset.resource
      |> Ash.Resource.validations(:create)
      |> Enum.reduce(changeset, fn validation, changeset ->
        if validation.expensive? and not changeset.valid? do
          changeset
        else
          do_validation(changeset, validation)
        end
      end)
    end)
  end

  defp do_validation(changeset, validation) do
    case validation.module.validate(changeset, validation.opts) do
      :ok -> changeset
      {:error, error} -> Ash.Changeset.add_error(changeset, error)
    end
  end

  defp set_defaults(changeset) do
    changeset.resource
    |> Ash.Resource.attributes()
    |> Enum.filter(&(not is_nil(&1.default)))
    |> Enum.reduce(changeset, fn attribute, changeset ->
      Ash.Changeset.change_new_attribute_lazy(changeset, attribute.name, fn ->
        default(attribute.default)
      end)
    end)
  end

  defp do_run_requests(
         changeset,
         upsert?,
         engine_opts,
         action,
         resource,
         api
       ) do
    authorization_request =
      Request.new(
        api: api,
        resource: resource,
        changeset: Relationships.changeset(changeset),
        action: action,
        data: nil,
        path: [:data],
        name: "#{action.type} - `#{action.name}`: prepare"
      )

    relationship_read_requests = changeset.requests

    commit_request =
      Request.new(
        api: api,
        resource: resource,
        changeset:
          Request.resolve([[:data, :changeset]], fn %{data: %{changeset: changeset}} ->
            {:ok, changeset}
          end),
        action: action,
        data:
          Request.resolve(
            [[:commit, :changeset]],
            fn %{commit: %{changeset: changeset}} ->
              Ash.Changeset.with_hooks(changeset, fn changeset ->
                if upsert? do
                  Ash.DataLayer.upsert(resource, changeset)
                else
                  Ash.DataLayer.create(resource, changeset)
                end
              end)
            end
          ),
        path: [:commit],
        name: "#{action.type} - `#{action.name}`: commit"
      )

    Engine.run(
      [authorization_request | [commit_request | relationship_read_requests]],
      api,
      engine_opts
    )
  end

  defp check_upsert_support(_resource, false), do: :ok

  defp check_upsert_support(resource, true) do
    if Ash.Resource.data_layer_can?(resource, :upsert) do
      :ok
    else
      {:error, {:unsupported, :upsert}}
    end
  end

  defp default({mod, func, args}), do: apply(mod, func, args)
  defp default(function) when is_function(function, 0), do: function.()
  defp default(value), do: value
end
