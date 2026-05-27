from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from app.routes import customers, services, therapists, rooms, appointments

app = FastAPI(title="Wellness Management API")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # tighten this later
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(customers.router, prefix="/customers", tags=["Customers"])
app.include_router(services.router, prefix="/services", tags=["Services"])
app.include_router(therapists.router, prefix="/therapists", tags=["Therapists"])
app.include_router(rooms.router, prefix="/rooms", tags=["Rooms"])
app.include_router(appointments.router, prefix="/appointments", tags=["Appointments"])

@app.get("/")
def health_check():
    return {"status": "API is running"}