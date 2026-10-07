defmodule EventSales.Analytics.Resources.AnalyticsContributionFact do
  @moduledoc """
  Durable exact sale and refund contributions used to compose partial period edges.

  Sale identities come from normalized OrderItem UUIDs. Refund identities come
  from RefundLine UUIDs and require exact parent-line attribution. Reference-only,
  unresolved, header-only, unbound, and voided refund evidence is not represented
  by a contribution row.

  Missing contribution rows do not mean zero activity. A future edge read must
  first verify the containing event bucket coverage envelope.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: EventSales.Analytics

  alias EventSales.Analytics.Validations.ValidateContributionFactIdentity
  alias EventSales.Analytics.Validations.ValidateContributionFactShape

  @contribution_kinds [:sale, :refund]

  @kind_shape_check """
  (
    (contribution_kind = 'sale'
     AND gross_ticket_quantity > 0
     AND gross_ticket_value >= 0
     AND refund_ticket_quantity = 0
     AND refund_ticket_value = 0)
    OR
    (contribution_kind = 'refund'
     AND gross_ticket_quantity = 0
     AND gross_ticket_value = 0
     AND refund_ticket_quantity >= 0
     AND refund_ticket_value >= 0
     AND (refund_ticket_quantity > 0 OR refund_ticket_value > 0))
  )
  """

  postgres do
    table "analytics_contribution_facts"
    repo EventSales.Repo

    references do
      reference :event, on_delete: :delete, on_update: :update
      reference :ticket_type, on_delete: :restrict, on_update: :update
      reference :source_system, on_delete: :restrict, on_update: :update
    end

    custom_indexes do
      index [:contribution_kind, :source_contribution_id],
        unique: true,
        name: "analytics_contribution_facts_source_identity_uidx"

      index [:event_id, :currency, :effective_at],
        name: "analytics_contribution_facts_event_currency_effective_at_idx"
    end

    check_constraints do
      check_constraint :coverage_identity,
        name: "analytics_contribution_facts_coverage_identity_check",
        check: "char_length(coverage_identity) > 0"

      check_constraint :gross_ticket_quantity,
        name: "analytics_contribution_facts_gross_quantity_check",
        check: "gross_ticket_quantity >= 0"

      check_constraint :gross_ticket_value,
        name: "analytics_contribution_facts_gross_value_check",
        check: "gross_ticket_value >= 0"

      check_constraint :refund_ticket_quantity,
        name: "analytics_contribution_facts_refund_quantity_check",
        check: "refund_ticket_quantity >= 0"

      check_constraint :refund_ticket_value,
        name: "analytics_contribution_facts_refund_value_check",
        check: "refund_ticket_value >= 0"

      check_constraint :woo_product_id,
        name: "analytics_contribution_facts_woo_product_id_check",
        check: "woo_product_id > 0"

      check_constraint :woo_variation_id,
        name: "analytics_contribution_facts_woo_variation_id_check",
        check: "woo_variation_id IS NULL OR woo_variation_id > 0"

      check_constraint :semantic_version,
        name: "analytics_contribution_facts_semantic_version_check",
        check: "semantic_version >= 1"

      check_constraint :contribution_kind,
        name: "analytics_contribution_facts_kind_shape_check",
        check: @kind_shape_check
    end
  end

  actions do
    defaults [:read]

    create :create_fact do
      accept [
        :contribution_kind,
        :source_contribution_id,
        :event_id,
        :currency,
        :effective_at,
        :ticket_type_id,
        :source_system_id,
        :woo_product_id,
        :woo_variation_id,
        :gross_ticket_quantity,
        :gross_ticket_value,
        :refund_ticket_quantity,
        :refund_ticket_value,
        :generation_id,
        :semantic_version,
        :coverage_identity,
        :refreshed_at,
        :source_watermark_at
      ]

      validate present([
                 :contribution_kind,
                 :source_contribution_id,
                 :event_id,
                 :currency,
                 :effective_at,
                 :ticket_type_id,
                 :source_system_id,
                 :woo_product_id,
                 :generation_id,
                 :semantic_version,
                 :coverage_identity,
                 :refreshed_at
               ])

      validate {ValidateContributionFactShape, []}
      validate {ValidateContributionFactIdentity, []}
    end

    update :update_fact do
      accept [
        :event_id,
        :currency,
        :effective_at,
        :ticket_type_id,
        :source_system_id,
        :woo_product_id,
        :woo_variation_id,
        :gross_ticket_quantity,
        :gross_ticket_value,
        :refund_ticket_quantity,
        :refund_ticket_value,
        :generation_id,
        :semantic_version,
        :coverage_identity,
        :refreshed_at,
        :source_watermark_at
      ]

      require_atomic? false
      validate {ValidateContributionFactShape, []}
      validate {ValidateContributionFactIdentity, []}
    end

    destroy :destroy_fact do
      primary? true
      accept []
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :contribution_kind, :atom do
      allow_nil? false
      constraints one_of: @contribution_kinds
      public? true
    end

    attribute :source_contribution_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :currency, :string do
      allow_nil? false
      public? true
    end

    attribute :effective_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :woo_product_id, :integer do
      allow_nil? false
      constraints min: 1
      public? true
    end

    attribute :woo_variation_id, :integer do
      constraints min: 1
      public? true
    end

    attribute :gross_ticket_quantity, :integer do
      allow_nil? false
      default 0
      constraints min: 0
      public? true
    end

    attribute :gross_ticket_value, :decimal do
      allow_nil? false
      default Decimal.new("0")
      constraints min: 0
      public? true
    end

    attribute :refund_ticket_quantity, :integer do
      allow_nil? false
      default 0
      constraints min: 0
      public? true
    end

    attribute :refund_ticket_value, :decimal do
      allow_nil? false
      default Decimal.new("0")
      constraints min: 0
      public? true
    end

    attribute :generation_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :semantic_version, :integer do
      allow_nil? false
      constraints min: 1
      public? true
    end

    attribute :coverage_identity, :string do
      allow_nil? false
      constraints min_length: 1
      public? true
    end

    attribute :refreshed_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :source_watermark_at, :utc_datetime_usec do
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :event, EventSales.Catalog.Resources.Event do
      allow_nil? false
      public? true
    end

    belongs_to :ticket_type, EventSales.Catalog.Resources.TicketType do
      allow_nil? false
      public? true
    end

    belongs_to :source_system, EventSales.Catalog.Resources.SourceSystem do
      allow_nil? false
      public? true
    end
  end
end
