Mix.Task.run("app.start")

alias EventSales.Ingestion.Security.WebhookSignature

secret = System.get_env("WOOCOMMERCE_WEBHOOK_SECRET", "slice_1_5_webhook_secret")
raw_body = ~s({"id":1,"smoke_signature_test":true})

signature = WebhookSignature.sign(raw_body, secret)

if WebhookSignature.verify(raw_body, secret, signature) == :ok do
  IO.puts("webhook signature smoke: passed")
else
  IO.puts("webhook signature smoke: failed")
  System.halt(1)
end
