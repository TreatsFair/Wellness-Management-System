from fastapi import APIRouter
from app.firebase import db

router = APIRouter()

@router.get("/")
def get_customers():
    docs = db.collection("customers").stream()
    customers = []
    for doc in docs:
        data = doc.to_dict()
        data["id"] = doc.id
        customers.append(data)
    return customers