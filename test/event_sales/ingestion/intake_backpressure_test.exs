defmodule EventSales.Ingestion.IntakeBackpressureTest do
  use ExUnit.Case, async: true

  alias EventSales.Ingestion.IntakeBackpressure

  @unique_delivery_id_constraint "ingestion_webhook_events_unique_delivery_id_index"

  test "queue_timeout ConnectionError is pool saturated" do
    err = %DBConnection.ConnectionError{message: "queue_timeout", reason: :queue_timeout}

    assert IntakeBackpressure.pool_saturated?(err)
    assert {:pool_saturated, ^err} = IntakeBackpressure.classify_persist_error(err)
  end

  test "checkout timeout ConnectionError is pool saturated" do
    err = %DBConnection.ConnectionError{
      message: "connection not available and request was dropped from queue after 5000ms",
      reason: :timeout
    }

    assert IntakeBackpressure.pool_saturated?(err)
    assert {:pool_saturated, ^err} = IntakeBackpressure.classify_persist_error(err)
  end

  test "unique constraint is not pool saturated" do
    err = %Ash.Error.Invalid{
      errors: [
        %Ash.Error.Changes.InvalidAttribute{
          field: :delivery_id,
          private_vars: [constraint: @unique_delivery_id_constraint]
        }
      ]
    }

    refute IntakeBackpressure.pool_saturated?(err)
    assert {:other, ^err} = IntakeBackpressure.classify_persist_error(err)
  end

  test "generic Ash error is not pool saturated" do
    err = %Ash.Error.Invalid{errors: []}

    refute IntakeBackpressure.pool_saturated?(err)
    assert {:other, ^err} = IntakeBackpressure.classify_persist_error(err)
  end
end
