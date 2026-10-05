Logger.configure(level: :warning)
{:ok, _apps} = Application.ensure_all_started(:jido_action)
ExUnit.start()
