# Subscription-level guardrails.
#
# Its OWN state file, deliberately. Everything here must OUTLIVE a
# `terraform destroy` of the lab - a budget that disappears with the resources it
# was watching is worse than no budget, because you stop receiving alerts at
# exactly the moment you rebuild and start spending again.
#
# Same reasoning that put the tfstate backend outside every module.

# --- Monthly budget -------------------------------------------------------
#
# IMPORTED, not created. This budget was clicked together on Day 1 and has been
# quietly protecting the account for eleven days. Recreating it would mean
# deleting a working control and hoping the replacement comes up correctly.
#
#   terraform import azurerm_consumption_budget_subscription.lab \
#     "/subscriptions/<sub>/providers/Microsoft.Consumption/budgets/lab-monthly-budget"
#
# Import is how real infrastructure gets adopted. Almost nothing greenfield stays
# greenfield: there is always a resource someone made by hand that now has to
# join the repo without an outage.
#
# WHAT A BUDGET ACTUALLY DOES: it notifies. It does NOT cap, throttle, or stop
# anything. Azure will happily bill past it. The only real stop is your own
# teardown discipline - which is why the autodelete tag and the no-NAT-gateway
# decision mattered more than this resource does.
#
# It is still the fastest signal you have: budgets evaluate several times a day,
# whereas system.billing.usage lags ~24h. Alerting and analysis are different
# jobs and want different tools.
resource "azurerm_consumption_budget_subscription" "lab" {
  name            = "lab-monthly-budget"
  subscription_id = "/subscriptions/${var.subscription_id}"

  amount     = var.monthly_budget_inr
  time_grain = "Monthly"

  # start_date must be the first of a month. Azure rejects a start date more than
  # three months in the past on CREATE, which is a genuine trap when adopting an
  # old budget - another argument for importing rather than recreating.
  time_period {
    start_date = "2026-09-01T00:00:00Z"
    end_date   = "2027-09-01T00:00:00Z"
  }

  # Three ACTUAL thresholds plus one FORECAST.
  #
  # The forecast alert is the one that earns its place: actual-100% tells you the
  # money is already gone, while forecast-100% fires when Azure projects you will
  # breach at the current burn rate - usually days earlier, while you can still
  # act. If you keep only one alert, keep that one.
  notification {
    enabled        = true
    threshold      = 50
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = [var.alert_email]
  }

  notification {
    enabled        = true
    threshold      = 80
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = [var.alert_email]
  }

  notification {
    enabled        = true
    threshold      = 100
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = [var.alert_email]
  }

  notification {
    enabled        = true
    threshold      = 100
    operator       = "GreaterThan"
    threshold_type = "Forecasted"
    contact_emails = [var.alert_email]
  }
}
