
#include "Precomp.h"
#include "ObjectTravelInfo.h"
#include "Packages/Core/UClass.h"
#include "Packages/Core/Properties/UObjectProperty.h"
#include "Packages/Engine/Actors/UActor.h"
#include "Packages/Engine/Actors/Pawn/UPlayerPawn.h"
#include "Engine.h"
#include "Package/PackageManager.h"

#include <string>
#include <sstream>
#include <algorithm>

std::string ActorTravelInfo::Create(UPlayerPawn* pawn, bool transferItems)
{
	// Collect all actors we need to travel and give them a name each

	std::map<UObject*, std::string> travelObjectNames;
	Array<UObject*> processList;

	if (pawn)
	{
		travelObjectNames[pawn] = "player";
		processList.push_back(pawn);
	}

	if (transferItems)
	{
		for (size_t i = 0; i < processList.size(); i++)
		{
			UObject* cur = processList[i];
			for (UProperty* property : cur->GetAllTravelProperties())
			{
				if (auto objProperty = UObject::TryCast<UObjectProperty>(property))
				{
					for (int element = 0; element < property->ArrayDimension; ++element)
                    {
                    UObject* value = *static_cast<UObject**>(property->GetElement(cur->GetProperty(objProperty), element));
					if (value && travelObjectNames.find(value) == travelObjectNames.end())
					{
						std::string name = "item" + std::to_string(processList.size());
						travelObjectNames[value] = name;
						processList.push_back(value);
					}
                    }
				}
			}
		}
	}

	// Save each travel object
	Array<TravelObject> objectTravelInfo;
	for (UObject* object : processList)
	{
		objectTravelInfo.emplace_back(CreateObject(object, travelObjectNames[object], travelObjectNames));
	}
	return ToString(objectTravelInfo);
}

std::string ActorTravelInfo::ToString(const Array<TravelObject>& travelActors)
{
	// Example:
	// ClassName#player:prop1=value1;prop2=value2;prop3=value3...?ClassName#item1:prop1=value1;prop2=value2...

	std::string result = "SETRAVEL2\n";
	for (auto& object : travelActors)
	{
		result += object.ClassName + "#" + object.Name + ":";

		for (auto it = object.Properties.begin(); it != object.Properties.end(); it++)
		{
			result += it->first + "=";
            const char* hex = "0123456789ABCDEF";
            for (unsigned char c : it->second) {
                if (c == '%' || c == ';' || c == '?' || c == '\n' || c == '\r') {
                    result += '%'; result += hex[c >> 4]; result += hex[c & 15];
                } else result += c;
            }

			if (it != --object.Properties.end())
				result += ";";
		}

		result += "?";
	}
	return result;
}

ActorTravelInfo::TravelObject ActorTravelInfo::CreateObject(UObject* travelObject, const std::string& name, const std::map<UObject*, std::string>& travelObjects)
{
	TravelObject info;
	info.ClassName = UObject::GetUClassFullName(travelObject).ToString();
	info.Name = name;
    for (UProperty* property : travelObject->GetAllTravelProperties()) {
        for (int i=0; i<property->ArrayDimension; ++i) {
            auto key = property->Name.ToString() + (property->ArrayDimension > 1 ? "[" + std::to_string(i) + "]" : "");
            void* value = property->GetElement(travelObject->GetProperty(property), i);
            if (UObject::TryCast<UObjectProperty>(property)) {
                auto* object = *static_cast<UObject**>(value);
                auto it = travelObjects.find(object);
                if (it != travelObjects.end()) info.Properties[key] = it->second;
                // A null manager may have been freshly initialized by PostBeginPlay.
            } else if (property->ValueType == ExpressionValueType::ValueString) {
                info.Properties[key] = *static_cast<std::string*>(value);
            } else {
                info.Properties[key] = property->PrintValue(value);
            }
        }
    }
	return info;
}

Array<UObject*> ActorTravelInfo::Accept(UPlayerPawn* pawn, const std::string& travelInfo)
{
	Array<UObject*> acceptedObjects;
	Array<const TravelObject*> acceptedTravel;
	std::map<NameString, UObject*> nameToObject;

	Array<TravelObject> items = Parse(travelInfo);

	// Spawn the items
	for (const TravelObject& objInfo : items)
	{
		UObject* object = nullptr;
		if (objInfo.Name != "player")
		{
			UClass* cls = engine->packages->FindClass(objInfo.ClassName);

			UStruct* actorCls = cls;
			while (actorCls)
			{
				if (actorCls->Name == "Actor")
					break;
				actorCls = actorCls->BaseStruct;
			}

			if (actorCls)
			{
				object = pawn->Spawn(cls, pawn, NameString(), {}, {});
			}
			else if (cls)
			{
				object = engine->packages->GetTransientPackage()->NewObject({}, cls, ObjectFlags::Transient);
			}
			else
			{
				LogMessage("Warning: could not spawn travel object with class name: " + objInfo.ClassName);
			}
		}
		else
		{
			object = pawn;
		}

		if (object)
		{
			nameToObject[objInfo.Name] = object;
			acceptedObjects.push_back(object);
			acceptedTravel.push_back(&objInfo);
		}
	}

	// Set travel properties
	for (size_t i = 0, count = acceptedObjects.size(); i < count; i++)
	{
		const TravelObject& objInfo = *acceptedTravel[i];
		UObject* acceptedObject = acceptedObjects[i];

		for (UProperty* property : acceptedObject->GetAllTravelProperties())
		{
			// GetAllTravelProperties force-includes Inventory so Create() can walk the chain to
			// find what to carry. Outside Deus Ex it is not a real UE1 travel property (Actor.uc:
			// "var Inventory Inventory;", no travel keyword), and it must not be written back here:
			// UE1 rebuilds the chain in Inventory.TravelPreAccept -> GiveTo -> AddInventory, which
			// runs after this. Pre-linking it breaks scripts that ask whether the pawn already owns
			// an item - Translator.TravelPreAccept skips its Super call when
			// FindInventoryType(class) != None, and with the chain already wired it finds *itself*,
			// so it never gets BecomeItem()/GotoState('Idle2') and arrives as a visible world pickup
			// that no longer shows in the item list.
			if (property->Name == "Inventory" && !AllFlags(property->PropFlags, PropertyFlags::Travel))
				continue;

            for (int element=0; element<property->ArrayDimension; ++element) {
                auto key = property->Name.ToString() + (property->ArrayDimension > 1 ? "[" + std::to_string(element) + "]" : "");
                auto it = objInfo.Properties.find(key);
                if (it == objInfo.Properties.end() && element == 0) it = objInfo.Properties.find(property->Name.ToString());
                if (it == objInfo.Properties.end()) continue;
                void* value = property->GetElement(acceptedObject->GetProperty(property), element);
                if (UObject::TryCast<UObjectProperty>(property)) {
                    if (it->second == "None") *static_cast<UObject**>(value) = nullptr;
                    else {
                        auto object = nameToObject.find(it->second);
                        if (object == nameToObject.end()) Exception::Throw("Missing travel object: " + it->second);
                        *static_cast<UObject**>(value) = object->second;
                    }
                } else property->SetValueFromString(value, it->second);
            }
		}
	}

	// Important: we want the actor returned first, followed by inventory
	return acceptedObjects;
}

Array<ActorTravelInfo::TravelObject> ActorTravelInfo::Parse(const std::string& text)
{
	Array<TravelObject> result;

	bool escaped = text.rfind("SETRAVEL2\n", 0) == 0;
    std::stringstream textStream(escaped ? text.substr(10) : text);

	std::string propertyString;

	while (getline(textStream, propertyString, '?')) {
        auto object = ParseSingleObject(propertyString);
        if (escaped) for (auto& pair : object.Properties) {
            std::string value;
            for (size_t i=0; i<pair.second.size(); ++i) {
                if (pair.second[i] != '%') { value += pair.second[i]; continue; }
                auto digit = [](char c) -> int { if (c >= '0' && c <= '9') return c-'0'; if (c >= 'A' && c <= 'F') return c-'A'+10; return -1; };
                if (i+2 >= pair.second.size() || digit(pair.second[i+1]) < 0 || digit(pair.second[i+2]) < 0) Exception::Throw("Invalid escaped travel data");
                value += (char)((digit(pair.second[i+1]) << 4) | digit(pair.second[i+2])); i += 2;
            }
            pair.second = std::move(value);
        }
        result.push_back(std::move(object));
    }

	return result;
}

ActorTravelInfo::TravelObject ActorTravelInfo::ParseSingleObject(const std::string& singleObjectText)
{
	auto colonPos = singleObjectText.find(':');

	if (colonPos == std::string::npos)
		Exception::Throw("No Class name found while parsing " + singleObjectText);

	std::string classNameAndType = singleObjectText.substr(0, colonPos);
	std::string properties = singleObjectText.substr(colonPos + 1);

	auto hashtagPos = classNameAndType.find('#');

	if (hashtagPos == std::string::npos)
		Exception::Throw("No # discriminator found while parsing " + singleObjectText);

	TravelObject result;

	std::string className = classNameAndType.substr(0, hashtagPos);

	result.ClassName = className;

	result.Name = classNameAndType.substr(hashtagPos + 1);

	std::stringstream propStream(properties);

	std::string readProperty;

	while (getline(propStream, readProperty, ';'))
	{
		auto equalsPos = readProperty.find('=');

		if (equalsPos == std::string::npos)
			Exception::Throw("No = found while parsing property text: " + readProperty);

		std::string propName = readProperty.substr(0, equalsPos);
		std::string propValue = readProperty.substr(equalsPos + 1);

		result.Properties[propName] = propValue;
	}

	return result;
}
