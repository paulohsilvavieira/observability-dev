class HomeController < ActionController::API
  def index
     

     APP_TRACER.in_span("ActivitiesController#show") do |span|
        Rails.logger.warn "teste de tracing"
      span.set_attribute("controller.action", "show")
      span.set_attribute("controller.name", "ActivitiesController")
      span.set_attribute("params.id",' params[:id]')

        COUNTER.add(1, attributes: {
          "user_id" => "1",
          "location" => "trail.location",
          "duration" => "duration"
        }
      )
      date =  DateTime.now
      render json: date
    end
  end
end
