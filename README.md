# How to Use it

- Add capybara_sync.rb to your lib folder
- set your default driver, as below

```ruby
if ENV["DRIVER"] == "SELENIUM"
  Capybara.default_driver = :selenium
  Capybara.javascript_driver = :selenium
else
  Capybara.default_driver = :poltergeist_sync
  Capybara.javascript_driver = :poltergeist_sync
end
```
