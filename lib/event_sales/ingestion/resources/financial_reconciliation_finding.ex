defmodule EventSales.Ingestion.Resources.FinancialReconciliationFinding do
  @moduledoc """
  Durable structural diagnostic finding for one financial reconciliation run.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: EventSales.Ingestion

  alias EventSales.Ingestion.FinancialReconciliation.FindingFingerprint
  alias EventSales.Ingestion.Validations.AuthorizedFinancialReconciliationStateMutation

  @structural_categories [
    :source_snapshot_stale,
    :refund_identity_drift,
    :http_under_lock,
    :historical_recognition_unproven,
    :timestamp_incomplete,
    :currency_conflict,
    :unresolved_attribution,
    :financial_primitive_incomplete,
    :missing_source_fact,
    :missing_refund_detail,
    :missing_local_fact,
    :invalid_scope,
    :comparison_scope_mismatch,
    :invalid_comparison_input
  ]

  @numeric_mismatch_categories [
    :gross_quantity_mismatch,
    :gross_value_mismatch,
    :refund_quantity_mismatch,
    :refund_value_mismatch,
    :net_quantity_mismatch,
    :net_value_mismatch
  ]

  @origins [:source, :local, :comparator]
  @max_details_bytes 4096
  @category_check_sql "category IN (#{Enum.map_join(@structural_categories, ", ", &"'#{&1}'")})"

  @persist_accept [
    :financial_reconciliation_run_id,
    :category,
    :origin,
    :details,
    :fingerprint
  ]

  postgres do
    table "ingestion_financial_reconciliation_findings"
    repo EventSales.Repo

    references do
      reference :financial_reconciliation_run, on_delete: :restrict, on_update: :update
    end

    custom_indexes do
      index :financial_reconciliation_run_id,
        name: "ingestion_fin_recon_findings_run_id_idx"

      index :category, name: "ingestion_fin_recon_findings_category_idx"
      index :origin, name: "ingestion_fin_recon_findings_origin_idx"
    end

    identity_index_names unique_run_fingerprint: "ingestion_fin_recon_findings_identity_idx"

    check_constraints do
      check_constraint :category,
        name: "ingestion_fin_recon_findings_category_check",
        check: @category_check_sql

      check_constraint :origin,
        name: "ingestion_fin_recon_findings_origin_check",
        check: "origin IN ('source', 'local', 'comparator')"

      check_constraint :fingerprint,
        name: "ingestion_fin_recon_findings_fingerprint_check",
        check: "fingerprint ~ '^[0-9a-f]{64}$'"
    end
  end

  actions do
    defaults [:read]

    create :persist do
      accept @persist_accept
      validate {AuthorizedFinancialReconciliationStateMutation, []}

      validate present([
                 :financial_reconciliation_run_id,
                 :category,
                 :origin,
                 :details,
                 :fingerprint
               ])

      validate &__MODULE__.validate_structural_category/2
      validate &__MODULE__.validate_origin/2
      validate &__MODULE__.validate_details/2
      validate &__MODULE__.validate_fingerprint/2
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :category, :atom do
      allow_nil? false
      constraints one_of: @structural_categories
      public? true
    end

    attribute :origin, :atom do
      allow_nil? false
      constraints one_of: @origins
      public? true
    end

    attribute :details, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :fingerprint, :string do
      allow_nil? false
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :financial_reconciliation_run,
               EventSales.Ingestion.Resources.FinancialReconciliationRun do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_run_fingerprint, [:financial_reconciliation_run_id, :fingerprint]
  end

  def structural_categories, do: @structural_categories
  def numeric_mismatch_categories, do: @numeric_mismatch_categories

  def validate_structural_category(changeset, _context) do
    category = Ash.Changeset.get_attribute(changeset, :category)

    cond do
      category in @numeric_mismatch_categories ->
        {:error, field: :category, message: "numeric mismatch categories belong in metrics"}

      category in @structural_categories ->
        :ok

      true ->
        {:error, field: :category, message: "unknown structural finding category"}
    end
  end

  def validate_origin(changeset, _context) do
    origin = Ash.Changeset.get_attribute(changeset, :origin)

    if origin in @origins do
      :ok
    else
      {:error, field: :origin, message: "invalid finding origin"}
    end
  end

  def validate_details(changeset, _context) do
    details = Ash.Changeset.get_attribute(changeset, :details) || %{}

    with {:ok, normalized} <- FindingFingerprint.normalize_details(details),
         {:ok, encoded} <- Jason.encode(normalized) do
      if byte_size(encoded) <= @max_details_bytes do
        :ok
      else
        {:error, field: :details, message: "details exceed maximum size of 4096 bytes"}
      end
    else
      {:error, _reason} ->
        {:error, field: :details, message: "details must be JSON-safe"}
    end
  end

  def validate_fingerprint(changeset, _context) do
    category = Ash.Changeset.get_attribute(changeset, :category)
    origin = Ash.Changeset.get_attribute(changeset, :origin)
    details = Ash.Changeset.get_attribute(changeset, :details) || %{}
    fingerprint = Ash.Changeset.get_attribute(changeset, :fingerprint)

    case FindingFingerprint.compute(category, origin, details) do
      {:ok, expected} ->
        cond do
          fingerprint == expected and byte_size(fingerprint) == 64 ->
            :ok

          fingerprint == expected ->
            {:error, field: :fingerprint, message: "fingerprint must be 64 lowercase hex chars"}

          true ->
            {:error, field: :fingerprint, message: "fingerprint does not match persisted details"}
        end

      {:error, _reason} ->
        {:error, field: :fingerprint, message: "unable to compute expected fingerprint"}
    end
  end
end
